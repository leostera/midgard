-module(todo_store).
-behaviour(gen_server).

-export([start_link/0, list/0, create/1, update/2, delete/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MAX_TITLE_BYTES, 160).
%% Even worst-case JSON escaping stays within the 64 KiB Midgard response frame.
-define(MAX_TODOS, 60).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
list() -> gen_server:call(?MODULE, list).
create(Title) -> gen_server:call(?MODULE, {create, Title}).
update(Id, Changes) -> gen_server:call(?MODULE, {update, Id, Changes}).
delete(Id) -> gen_server:call(?MODULE, {delete, Id}).

init([]) -> {ok, #{next_id => 1, todos => #{}}}.

handle_call(list, _From, #{todos := Todos} = State) ->
    Ordered = lists:sort(fun(#{id := A}, #{id := B}) -> A < B end,
                         maps:values(Todos)),
    {reply, Ordered, State};
handle_call({create, Title}, _From, #{next_id := Id, todos := Todos} = State) ->
    case valid_title(Title) of
        true when map_size(Todos) >= ?MAX_TODOS ->
            {reply, {error, full}, State};
        true ->
            Todo = #{id => Id, title => Title, completed => false},
            {reply, {ok, Todo}, State#{next_id := Id + 1,
                                      todos := Todos#{Id => Todo}}};
        false ->
            {reply, {error, invalid_title}, State}
    end;
handle_call({update, Id, Changes}, _From, #{todos := Todos} = State) ->
    case {maps:find(Id, Todos), valid_changes(Changes)} of
        {{ok, Todo}, true} ->
            Updated = maps:merge(Todo, Changes),
            {reply, {ok, Updated}, State#{todos := Todos#{Id := Updated}}};
        {error, _} ->
            {reply, {error, not_found}, State};
        {_, false} ->
            {reply, {error, invalid_changes}, State}
    end;
handle_call({delete, Id}, _From, #{todos := Todos} = State) ->
    case maps:is_key(Id, Todos) of
        true -> {reply, ok, State#{todos := maps:remove(Id, Todos)}};
        false -> {reply, {error, not_found}, State}
    end;
handle_call(_Other, _From, State) -> {reply, {error, invalid_request}, State}.

handle_cast(_Other, State) -> {noreply, State}.
handle_info(_Other, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

valid_title(Title) when is_binary(Title) ->
    byte_size(Title) > 0 andalso byte_size(Title) =< ?MAX_TITLE_BYTES
        andalso is_binary(unicode:characters_to_binary(Title, utf8, utf8))
        andalso binary:match(Title, [<<0>>, <<10>>, <<13>>]) =:= nomatch;
valid_title(_) -> false.

valid_changes(Changes) when is_map(Changes), map_size(Changes) > 0 ->
    lists:all(fun(Key) -> Key =:= title orelse Key =:= completed end,
              maps:keys(Changes)) andalso
    (not maps:is_key(title, Changes) orelse
       valid_title(maps:get(title, Changes))) andalso
    (not maps:is_key(completed, Changes) orelse
       is_boolean(maps:get(completed, Changes)));
valid_changes(_) -> false.
