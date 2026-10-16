// SPDX-License-Identifier: Apache-2.0
// Development host for libbeam_elixir. All libbeam handles live on this thread.
#include <libbeam/engine.hpp>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <optional>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/types.h>
#include <unistd.h>
#include <utility>
#include <variant>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr std::size_t max_frame = 32u * 1024u * 1024u;
constexpr std::uint8_t version = 1;
enum Operation : std::uint8_t { hello = 0, create = 1, load = 2, call = 3, stop = 4, shutdown = 5 };

struct Reader {
    std::string_view bytes;
    std::size_t cursor = 0;
    std::string_view take(std::size_t size) {
        if (size > bytes.size() - cursor) throw std::runtime_error("truncated command");
        auto piece = bytes.substr(cursor, size);
        cursor += size;
        return piece;
    }
    std::uint64_t integer(std::size_t size) {
        std::uint64_t value = 0;
        for (unsigned char byte : take(size)) value = (value << 8) | byte;
        return value;
    }
    bool done() const { return cursor == bytes.size(); }
};
void append(std::string& bytes, std::uint64_t value, std::size_t width) {
    for (std::size_t i = width; i; --i) bytes.push_back(static_cast<char>(value >> (8 * (i - 1))));
}
bool write_all(int fd, const char* bytes, std::size_t size) {
    while (size) {
        const auto written = ::write(fd, bytes, size);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return false;
        bytes += written;
        size -= static_cast<std::size_t>(written);
    }
    return true;
}
bool read_all(int fd, char* bytes, std::size_t size) {
    while (size) {
        const auto received = ::read(fd, bytes, size);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) return false;
        bytes += received;
        size -= static_cast<std::size_t>(received);
    }
    return true;
}
std::optional<std::string> read_frame() {
    char prefix[4];
    if (!read_all(STDIN_FILENO, prefix, sizeof(prefix))) return std::nullopt;
    Reader head{std::string_view(prefix, sizeof(prefix))};
    const auto length = head.integer(4);
    if (length < 10 || length > max_frame) throw std::runtime_error("invalid Port frame length");
    std::string frame(static_cast<std::size_t>(length), '\0');
    if (!read_all(STDIN_FILENO, frame.data(), frame.size())) return std::nullopt;
    return frame;
}
void send(std::uint64_t id, std::uint8_t status, std::string_view payload) {
    if (payload.size() + 10 > max_frame) throw std::runtime_error("reply exceeds Port frame bound");
    std::string frame;
    frame.reserve(payload.size() + 14);
    append(frame, payload.size() + 10, 4);
    frame.push_back(static_cast<char>(version));
    append(frame, id, 8);
    frame.push_back(static_cast<char>(status));
    frame.append(payload);
    if (!write_all(STDOUT_FILENO, frame.data(), frame.size())) throw std::runtime_error("Port output closed");
}
void fail(std::uint64_t id, libbeam::Error error) {
    std::string payload;
    append(payload, static_cast<unsigned>(error.code), 2);
    const auto length = std::min<std::size_t>(error.message.size(), 1024);
    append(payload, length, 2);
    payload.append(error.message.data(), length);
    send(id, 1, payload);
}
void bad(std::uint64_t id, std::string message) {
    fail(id, {libbeam::ErrorCode::invalid_argument, std::move(message)});
}
libbeam::ByteView view(std::string_view bytes) {
    return {reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size()};
}
struct IsolateRecord { libbeam::Isolate isolate; bool started = false; bool stopping = false; };
struct PendingCall { std::uint64_t isolate; libbeam::Call handle; };
struct PendingStop { std::uint64_t isolate; libbeam::Reclamation handle; };

class Host {
    libbeam::Engine engine;
    std::map<std::uint64_t, IsolateRecord> isolates;
    std::map<std::uint64_t, PendingCall> calls;
    std::map<std::uint64_t, PendingStop> stops;
    std::uint64_t next_isolate = 1;
    bool closing = false;

    void poll_completions() {
        for (auto it = calls.begin(); it != calls.end();) {
            auto outcome = it->second.handle.wait_until(Clock::time_point::min());
            if (auto* error = std::get_if<libbeam::Error>(&outcome);
                error && error->code == libbeam::ErrorCode::timeout) { ++it; continue; }
            if (auto* error = std::get_if<libbeam::Error>(&outcome)) fail(it->first, *error);
            else {
                const auto& result = std::get<libbeam::Bytes>(outcome);
                send(it->first, 0, std::string_view(reinterpret_cast<const char*>(result.data()), result.size()));
            }
            it = calls.erase(it);
        }
        for (auto it = stops.begin(); it != stops.end();) {
            auto error = it->second.handle.wait_until(Clock::time_point::min());
            if (error && error->code == libbeam::ErrorCode::timeout) { ++it; continue; }
            if (error) fail(it->first, *error);
            else { isolates.erase(it->second.isolate); send(it->first, 0, {}); }
            it = stops.erase(it);
        }
    }

    void dispatch(std::uint64_t id, Operation operation, Reader& payload) {
        if (id == 0 && operation != hello) throw std::runtime_error("reserved request ID");
        if (id != 0 && (calls.count(id) || stops.count(id))) throw std::runtime_error("duplicate request ID");
        switch (operation) {
        case hello:
            if (id != 0 || !payload.done()) throw std::runtime_error("invalid handshake");
            send(0, 0, "libbeam-port-v1");
            break;
        case create: {
            const auto memory = payload.integer(8), work = payload.integer(8);
            if (!payload.done()) throw std::runtime_error("trailing create payload");
            if (next_isolate == std::numeric_limits<std::uint64_t>::max()) { bad(id, "isolate IDs exhausted"); break; }
            libbeam::ResourceOverrides limits;
            if (memory) {
                if (memory > std::numeric_limits<std::size_t>::max()) { bad(id, "memory limit overflow"); break; }
                limits.memory_limit_bytes = static_cast<std::size_t>(memory);
            }
            if (work) limits.invocation_work_limit = work;
            auto result = engine.create_isolate(limits);
            if (auto* error = std::get_if<libbeam::Error>(&result)) { fail(id, *error); break; }
            const auto isolate_id = next_isolate++;
            isolates.emplace(isolate_id, IsolateRecord{std::move(std::get<libbeam::Isolate>(result))});
            std::string bytes; append(bytes, isolate_id, 8); send(id, 0, bytes);
            break;
        }
        case load: {
            const auto isolate_id = payload.integer(8), count = payload.integer(4);
            const auto policy = payload.integer(1);
            if (!count || count > 512 || policy > 1) throw std::runtime_error("invalid module load options");
            std::vector<libbeam::ByteView> modules;
            modules.reserve(static_cast<std::size_t>(count));
            for (std::uint64_t i = 0; i < count; ++i) modules.push_back(view(payload.take(payload.integer(4))));
            if (!payload.done()) throw std::runtime_error("trailing module data");
            auto entry = isolates.find(isolate_id);
            if (entry == isolates.end() || entry->second.stopping) { bad(id, "unknown or stopped isolate"); break; }
            libbeam::ModuleLoadOptions options;
            if (policy) options.on_load = libbeam::OnLoadPolicy::defer_denied_nif;
            if (auto error = entry->second.isolate.load_modules(modules, options)) fail(id, *error);
            else send(id, 0, {});
            break;
        }
        case call: {
            const auto isolate_id = payload.integer(8);
            const auto module = payload.take(payload.integer(2));
            const auto function = payload.take(payload.integer(2));
            const auto input = payload.take(payload.integer(4));
            if (!payload.done() || module.empty() || function.empty() || input.size() > 65536)
                throw std::runtime_error("invalid call payload");
            auto entry = isolates.find(isolate_id);
            if (entry == isolates.end() || entry->second.stopping) { bad(id, "unknown or stopped isolate"); break; }
            auto result = entry->second.started
                ? entry->second.isolate.call(module, function, view(input))
                : entry->second.isolate.start(module, function, view(input));
            if (auto* error = std::get_if<libbeam::Error>(&result)) fail(id, *error);
            else {
                entry->second.started = true;
                calls.emplace(id, PendingCall{isolate_id, std::move(std::get<libbeam::Call>(result))});
            }
            break;
        }
        case stop: {
            const auto isolate_id = payload.integer(8);
            if (!payload.done()) throw std::runtime_error("trailing stop payload");
            auto entry = isolates.find(isolate_id);
            if (entry == isolates.end() || entry->second.stopping) { bad(id, "unknown or stopped isolate"); break; }
            auto result = entry->second.isolate.stop();
            if (auto* error = std::get_if<libbeam::Error>(&result)) fail(id, *error);
            else {
                entry->second.stopping = true;
                stops.emplace(id, PendingStop{isolate_id, std::move(std::get<libbeam::Reclamation>(result))});
            }
            break;
        }
        case shutdown:
            if (!payload.done()) throw std::runtime_error("trailing shutdown payload");
            if (!isolates.empty() || !calls.empty() || !stops.empty()) bad(id, "stop all isolates first");
            else if (auto error = engine.shutdown(Clock::now() + std::chrono::seconds(30))) fail(id, *error);
            else { send(id, 0, {}); closing = true; }
            break;
        default: throw std::runtime_error("unknown Port operation");
        }
    }

public:
    explicit Host(libbeam::Engine owned) : engine(std::move(owned)) {}
    void run() {
        while (!closing) {
            poll_completions();
            pollfd source{STDIN_FILENO, POLLIN, 0};
            int result;
            do { result = ::poll(&source, 1, calls.empty() && stops.empty() ? -1 : 2); }
            while (result < 0 && errno == EINTR);
            if (result < 0) throw std::runtime_error("Port input poll failed");
            if (!result) continue;
            if (!(source.revents & POLLIN)) break;
            auto frame = read_frame();
            if (!frame) break;
            Reader reader{*frame};
            if (reader.integer(1) != version) throw std::runtime_error("Port protocol version mismatch");
            const auto id = reader.integer(8);
            const auto op = static_cast<Operation>(reader.integer(1));
            try { dispatch(id, op, reader); }
            catch (const std::exception& error) { bad(id, error.what()); }
        }
        // On unexpected EOF/Port death, destroy handles only on this thread.
        for (auto& [_, isolate] : isolates) {
            if (!isolate.stopping) (void)isolate.isolate.stop();
        }
        calls.clear(); stops.clear(); isolates.clear();
        (void)engine.shutdown(Clock::now() + std::chrono::seconds(30));
    }
};
} // namespace

int main() {
    try {
        auto engine = libbeam::Engine::create();
        if (auto* error = std::get_if<libbeam::Error>(&engine)) {
            std::fprintf(stderr, "libbeam engine: %s\n", error->message.c_str());
            return 1;
        }
        Host host(std::move(std::get<libbeam::Engine>(engine)));
        host.run();
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "libbeam host: %s\n", error.what());
        return 1;
    }
}
