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
    KeyModule = key_module(Opts),
    Key = KeyModule:generate_key(Name, Module, FunctionAtom, Args),
    case erl_cache:get(Name, Key, Opts) of
        {ok, Result} ->
            fun() -> Result end;
        {error, not_found} ->
            cache_setter(Name, Key, Opts, Fun, Args);
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
key_module(Opts) ->
    case proplists:get_value(key_generation, Opts) of
        undefined -> ?MODULE;
        KeyMod when is_atom(KeyMod) -> KeyMod;
        _ -> ?MODULE
    end.

cache_setter(Name, Key, Opts, Fun, Args) ->
    Callback = fun() -> Fun(Args) end,
    SetOpts = [{refresh_callback, Callback} | Opts],
    fun() ->
            Value = Callback(),
            ok = erl_cache:set(Name, Key, Value, SetOpts),
            Value
    end.
