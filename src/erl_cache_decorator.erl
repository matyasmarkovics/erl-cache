-module(erl_cache_decorator).
-behaviour(erl_cache_key_generator).

-export([cache_pt/3]).
-export([generate_key/4]).

%% ====================================================================
%% API
%% ====================================================================
-spec cache_pt(Fun, Args, Decoration) -> Arity0Fun when
      Fun::function(),
      Args::[term()],
      Decoration::{Module::module(), FunctionAtom::atom(), Name, Opts},
      Name::erl_cache:name(),
      Opts::erl_cache:cache_opts(),
      Arity0Fun::fun(() -> term()).
cache_pt(Fun, Args, {Module, FunctionAtom, Name, Opts}) ->
    KeyModule = case proplists:get_value(key_generation, Opts) of
                    undefined -> ?MODULE;
                    KeyMod when is_atom(KeyMod) -> KeyMod;
                    _ -> ?MODULE
                end,
    Key = KeyModule:generate_key(Name, Module, FunctionAtom, Args),
    GetOpts = proplists:lookup_all(wait_for_refresh, Opts),
    case erl_cache:get(Name, Key, GetOpts) of
        {ok, Result} ->
            fun() -> Result end;
        {error, not_found} ->
            Curried = fun() -> Fun(Args) end,
            cache_setter(Name, Key, Curried, Opts);
        {error, Err} ->
            throw({error, {cache_pt, Err}})
    end.

%% ====================================================================
%% Behaviour callback
%% ====================================================================
generate_key(_Name,  Module, FunctionAtom, Args) ->
    {decorated, Module, FunctionAtom, crypto:hash(sha, erlang:term_to_binary(Args))}.

%% ====================================================================
%% Internal
%% ====================================================================
cache_setter(Name, Key, Curried, Opts) ->
    SetOpts = [{refresh_callback, Curried} | proplists:delete(wait_for_refresh, Opts)],
    fun() ->
            Value = Curried(),
            ok = erl_cache:set(Name, Key, Value, SetOpts),
            Value
    end.
