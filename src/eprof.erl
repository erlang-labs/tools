%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 1996-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%
%% Purpose: Profile a system in order to figure out where the 
%% time goes.
%%

-module(eprof).
-behaviour(gen_server).

-export([start/0,
	 stop/0,
	 dump/0,
	 start_profiling/1, start_profiling/2,
	 profile/1, profile/2, profile/3, profile/4, profile/5,
	 stop_profiling/0,
	 analyze/0, analyze/1, analyze/2,
	 log/1]).

%% Internal exports 
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).
-record(bpd, {
	n   = 0,
	us  = 0,
	p   = gb_trees:empty(),
	mfa = []
    }).

-record(state, {
	profiling = false,
	pattern   = {'_','_','_'},
	rootset   = [],
	start_ts  = undefined,
	reply     = undefined,
	bpd       = #bpd{}
    }).



%% -------------------------------------------------------------------- %%
%%
%% API
%%
%% -------------------------------------------------------------------- %%

start() -> gen_server:start({local, ?MODULE}, ?MODULE, [], []).
stop()  -> gen_server:call(?MODULE, stop, infinity).

profile(Fun) when is_function(Fun) ->
    profile([], Fun);
profile(Rs) when is_list(Rs) ->
    start_profiling(Rs).

profile(Pids, Fun) ->
    profile(Pids, Fun, {'_','_','_'}).

profile(Pids, Fun, Pattern) ->
    profile(Pids, Pattern, erlang, apply, [Fun,[]]).

profile(Pids, M, F, A) ->
    profile(Pids, {'_','_','_'}, M, F, A).

profile(Pids, Pattern, M, F, A) ->
    start(),
    gen_server:call(?MODULE, {profile,Pids,Pattern, M,F,A},infinity).

dump() -> 
    gen_server:call(?MODULE, dump, infinity).

analyze() ->
    analyze(procs).

analyze(Type) when is_atom(Type) ->
    analyze(Type, []);
analyze(Opts) when is_list(Opts) ->
    analyze(procs, Opts).
analyze(Type, Opts) when is_list(Opts) ->
    gen_server:call(?MODULE, {analyze, Type, Opts}, infinity).

log(File) ->
    gen_server:call(?MODULE, {logfile, File}, infinity).

start_profiling(Rootset) ->
    start_profiling(Rootset, {'_','_','_'}).
start_profiling(Rootset, Pattern) ->
    start(),
    gen_server:call(?MODULE, {profile, Rootset, Pattern}, infinity).

stop_profiling() ->
    gen_server:call(?MODULE, stop_profiling, infinity).


%% -------------------------------------------------------------------- %%
%%
%% init
%%
%% -------------------------------------------------------------------- %%

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

%% -------------------------------------------------------------------- %%
%%
%% handle_call
%%
%% -------------------------------------------------------------------- %%

%% analyze

sum_bp_total_n_us(Mfas) ->
    lists:foldl(fun ({_, {Ci,Usi}}, {Co, Uso}) -> {Co + Ci, Uso + Usi} end, {0,0}, Mfas).

print_bp_mfa(Mfas, {_Tn, Tus}, Opts) ->
    print(["FUNCTION", "CALLS", "  %", "TIME", "uS / CALLS"]),
    print(["--------", "-----", "---", "----", "----------"]),
    lists:foreach(fun
	    ({_, {Count, Time}}) when Count =:= 0; Time < 1 ->
		ok;
	    ({Mfa, {Count, Time}}) ->
		print([s(Mfa), s(Count), s("~.2f", [100*(Time/Tus)]), s(Time), s("~.2f", [Time/Count])]),
		ok
	end, filter_mfa(sort_mfa(Mfas, proplists:get_value(sort, Opts)), proplists:get_value(thresholds, Opts))),
    ok.

handle_call({analyze, _, _}, _, #state{ bpd = #bpd{ p = {0,nil}, us = 0, n = 0} = Bpd } = S) when is_record(Bpd, bpd) ->
    {reply, nothing_to_analyze, S};
handle_call({analyze, procs, Opts}, _, #state{ bpd = #bpd{ p = Ps, us = Tus} = Bpd} = S) when is_record(Bpd, bpd) ->
    lists:foreach(fun
	    ({Pid, Mfas}) ->
		{Pn, Pus} =  sum_bp_total_n_us(Mfas),
		io:format("~n****** Process ~w    -- ~s % of profiled time *** ~n", [Pid, s("~.2f", [100.0*(Pus/Tus)])]),
		print_bp_mfa(Mfas, {Pn,Pus}, Opts),
		ok
	end, gb_trees:to_list(Ps)),
    {reply, ok, S};

handle_call({analyze, total, Opts}, _, #state{ bpd = #bpd{ mfa = Mfas, n = Tn, us = Tus} = Bpd} = S) when is_record(Bpd, bpd) ->
    print_bp_mfa(Mfas, {Tn, Tus}, Opts),
    {reply, ok, S};

handle_call({analyze, Type, _Opts}, _, S) ->
    {reply, {error, {undefined, Type}}, S};

%% profile

handle_call({profile, _Rootset, _Pattern, _M,_F,_A}, _From, #state{ profiling = true } = S)->
    {reply, {error, already_profiling}, S};

handle_call({profile, Rootset, Pattern, M,F,A}, From, S) ->

    set_pattern_trace(false, S#state.pattern),
    set_process_trace(false, S#state.rootset),

    Pid = setup_profiling(M,F,A),
    case set_process_trace(true, [Pid|Rootset]) of
	true ->
	    set_pattern_trace(true, Pattern),
	    T0 = now(),
	    execute_profiling(Pid),
	    {noreply, #state{
		    profiling = true,
		    rootset   = [Pid|Rootset],
		    start_ts  = T0,
		    reply     = From,
		    pattern   = Pattern
		}};
	false ->
	    exit(Pid, kill),
	    {reply, error, #state{}}
    end;

handle_call({profile, Rootset, Pattern}, From, S) ->

    set_pattern_trace(false, S#state.pattern),
    set_process_trace(false, S#state.rootset),

    case set_process_trace(true, Rootset) of
	true ->
	    T0 = now(),
	    set_pattern_trace(true, Pattern),
	    {reply, profiling, #state{
		    profiling = true,
		    rootset   = Rootset,
		    start_ts  = T0,
		    reply     = From,
		    pattern   = Pattern
		}};
	false ->
	    {reply, error, #state{}}
    end;

handle_call(stop_profiling, _From, #state{ profiling = false } = S) ->
    {reply, profiling_already_stopped, S};

handle_call(stop_profiling, _From, #state{ profiling = true } = S) ->

    set_pattern_trace(pause, S#state.pattern),

    Bpd = collect_bpd(),

    set_process_trace(false, S#state.rootset),
    set_pattern_trace(false, S#state.pattern),

    {reply, profiling_stopped, S#state{
	profiling = false,
	rootset   = [],
	pattern   = {'_','_','_'},
	bpd       = Bpd
    }};

handle_call(stop, _FromTag, S) ->
    {stop, normal, stopped, S}.

%% -------------------------------------------------------------------- %%
%%
%% handle_cast
%%
%% -------------------------------------------------------------------- %%

handle_cast(_Msg, State) ->
    {noreply, State}.

%% -------------------------------------------------------------------- %%
%%
%% handle_info
%%
%% -------------------------------------------------------------------- %%

handle_info({trace, _Pid, _Cmd, _Type}, S) ->
    {noreply, S};
handle_info({trace, _Parent, spawn, _Pid, _Mfa}, S) ->
    {noreply, S};
handle_info({'EXIT', _, normal}, S) ->
    {noreply, S};
handle_info({'EXIT', _, Reason}, #state{ reply = FromTag } = S) ->

    set_process_trace(false, S#state.rootset),
    set_pattern_trace(false, S#state.pattern),

    gen_server:reply(FromTag, {error, Reason}),
    {noreply, S#state{
	profiling = false,
	rootset   = [],
	pattern   = {'_','_','_'}
    }};

% check if Pid is spawned process?
handle_info({_Pid, {answer, Result}}, #state{ reply = {From,_} = FromTag} = S) ->

    set_pattern_trace(pause, S#state.pattern),

    Bpd = collect_bpd(),

    set_process_trace(false, S#state.rootset),
    set_pattern_trace(false, S#state.pattern),

    catch unlink(From),
    gen_server:reply(FromTag, {ok, Result}),
    {noreply, S#state{
	profiling = false,
	rootset   = [],
	pattern   = {'_','_','_'},
	bpd       = Bpd
    }};

handle_info(Info, State) ->
    io:format("handle_info: ~p~nstate: ~p~n", [Info,State]),
    {noreply, State}.

%% -------------------------------------------------------------------- %%
%%
%% termination
%%
%% -------------------------------------------------------------------- %%

terminate(_Reason, _State) ->
    set_pattern_trace(false, {'_','_','_'}),
    ok.

%% -------------------------------------------------------------------- %%
%%
%% code_change
%%
%% -------------------------------------------------------------------- %%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% -------------------------------------------------------------------- %%
%%
%% AUX Functions
%%
%% -------------------------------------------------------------------- %%

setup_profiling(M,F,A) ->
    spawn_link(fun() -> spin_profile(M,F,A) end).

spin_profile(M, F, A) ->
    receive
	{Pid, execute} ->
	    Pid ! {self(), {answer, erlang:apply(M,F,A)}}
    end.

execute_profiling(Pid) ->
    Pid ! {self(), execute}.

set_pattern_trace(Flag, Pattern) ->
    erlang:system_flag(multi_scheduling, block),
    erlang:trace_pattern(on_load, Flag, [call_time]),
    erlang:trace_pattern(Pattern, Flag, [call_time]),
    erlang:system_flag(multi_scheduling, unblock),
    ok.

set_process_trace(Flag, Pids) ->
    % do we need procs for meta info?
    % could be useful
    set_process_trace(Flag, Pids, [call, set_on_spawn]).
set_process_trace(_, [], _) -> true;
set_process_trace(Flag, [Pid|Pids], Options) when is_pid(Pid) ->
    try
	erlang:trace(Pid, Flag, Options)
    catch
	_:_ ->
	    false
    end,
    set_process_trace(Flag, Pids, Options);
set_process_trace(Flag, [Name|Pids], Options) when is_atom(Name) ->
    case whereis(Name) of
	undefined ->
	    set_process_trace(Flag, Pids, Options);
	Pid ->
	    set_process_trace(Flag, [Pid|Pids], Options)
    end.

collect_bpd() ->
    collect_bpd([M || M <- [element(1, Mi) || Mi <- code:all_loaded()], M =/= ?MODULE]).

collect_bpd(Ms) when is_list(Ms) ->
    collect_bpdf(collect_mfas(Ms) ++ erlang:system_info(snifs)).

collect_mfas(Ms) ->
    lists:foldl(fun
	    (M, Mfas) ->
		Mfas ++ [{M, F, A} || {F, A} <- M:module_info(functions)]
	end, [], Ms).

collect_bpdf(Mfas) ->
    collect_bpdf(Mfas, #bpd{}).
collect_bpdf([], Bpd) ->
    Bpd;
collect_bpdf([Mfa|Mfas], #bpd{n = N, us = Us, p = Tree, mfa = Code } = Bpd) ->
    case erlang:trace_info(Mfa, call_time) of
	{call_time, []} ->
	    collect_bpdf(Mfas, Bpd);
	{call_time, Data} when is_list(Data) ->
	    {CTn, CTus, CTree} = collect_bpdfp(Mfa, Tree, Data),
	    collect_bpdf(Mfas, Bpd#bpd{
		    n   = CTn  + N,
		    us  = CTus + Us,
		    p   = CTree,
		    mfa = [{Mfa, {CTn, CTus}}|Code]
		});
	{call_time, false} ->
	    collect_bpdf(Mfas, Bpd);
	{call_time, _Other} ->
	    collect_bpdf(Mfas, Bpd)
    end.

collect_bpdfp(Mfa, Tree, Data) ->
     lists:foldl(fun
	({Pid, Ni, Si, Usi}, {PTno, PTuso, To}) ->
	    Time = Si * 1000000 + Usi,
	    Ti1  = case gb_trees:lookup(Pid, To) of
		none ->
		    gb_trees:enter(Pid, [{Mfa, {Ni, Time}}], To);
		{value, Pmfas} ->
		    gb_trees:enter(Pid, [{Mfa, {Ni, Time}}|Pmfas], To)
	    end,
	    {PTno + Ni, PTuso + Time, Ti1}
    end, {0,0, Tree}, Data).

%% manipulators

sort_mfa(Bpfs, ascending) when is_list(Bpfs) ->
    lists:sort(fun
	    ({_,{_,A}}, {_,{_,B}}) when A > B -> true;
	    (_, _) -> false
	end, Bpfs);
sort_mfa(Bpfs, descending) when is_list(Bpfs) ->
    lists:sort(fun
	    ({_,{_,A}}, {_,{_,B}}) when A < B -> true;
	    (_, _) -> false
	end, Bpfs);
sort_mfa(Bpfs, _) when is_list(Bpfs) -> sort_mfa(Bpfs, ascending).

filter_mfa(Bpfs, Ts) when is_list(Ts) ->
    filter_mfa(Bpfs, [], proplists:get_value(calls, Ts, 0), proplists:get_value(time, Ts, 0));
filter_mfa(Bpfs, _) -> Bpfs.
filter_mfa([], Out, _, _) -> lists:reverse(Out);
filter_mfa([{_, {C, T}}=Bpf|Bpfs], Out, Ct, Tt) when C >= Ct, T >= Tt -> filter_mfa(Bpfs, [Bpf|Out], Ct, Tt);
filter_mfa([_|Bpfs], Out, Ct, Tt) -> filter_mfa(Bpfs, Out, Ct, Tt).


s({M,F,A}) -> s("~w:~w/~w",[M,F,A]);
s(Term) -> s("~p", [Term]).
s(Format, Terms) -> lists:flatten(io_lib:format(Format, Terms)).

print([_,_,_] = Strings) ->
    print("~.44s   ~14s ~14s~n", Strings);
print([_,_,_,_] = Strings) ->
    print("~.44s   ~14s ~14s ~7s ~n", Strings);
print(Strings) ->
    print("~.44s   ~14s ~14s ~7s [~7s]~n", Strings).
print(Format, Strings) ->
    io:format(Format, Strings).
