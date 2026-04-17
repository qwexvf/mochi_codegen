-module(mochi_codegen_ffi).
-export([glob/1]).

glob(Pattern) when is_binary(Pattern) ->
    Matches = filelib:wildcard(binary_to_list(Pattern)),
    lists:map(fun list_to_binary/1, lists:sort(Matches)).
