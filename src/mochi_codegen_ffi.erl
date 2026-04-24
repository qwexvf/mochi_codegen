-module(mochi_codegen_ffi).
-export([glob/1, run_command/1, get_cwd/0, resolve_path/1, unique_tmp_dir/1]).

glob(Pattern) when is_binary(Pattern) ->
    Matches = filelib:wildcard(binary_to_list(Pattern)),
    lists:map(fun list_to_binary/1, lists:sort(Matches)).

run_command(Cmd) when is_binary(Cmd) ->
    Output = os:cmd(binary_to_list(Cmd)),
    unicode:characters_to_binary(Output).

get_cwd() ->
    {ok, CWD} = file:get_cwd(),
    unicode:characters_to_binary(CWD).

resolve_path(Path) when is_binary(Path) ->
    Resolved = filename:absname(binary_to_list(Path)),
    unicode:characters_to_binary(Resolved).

unique_tmp_dir(Prefix) when is_binary(Prefix) ->
    Pid = os:getpid(),
    Unique = erlang:unique_integer([positive]),
    Name = io_lib:format("~s-~s-~p", [binary_to_list(Prefix), Pid, Unique]),
    Path = filename:join(["/tmp", lists:flatten(Name)]),
    unicode:characters_to_binary(Path).
