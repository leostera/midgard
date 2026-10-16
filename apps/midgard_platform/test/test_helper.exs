if System.get_env("LIBBEAM_PORT_NATIVE") == "1" do
  ExUnit.start()
else
  ExUnit.start(exclude: [native: true])
end
