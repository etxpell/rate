%%% ----------------------------------------------------------
%%% #0.    BASIC INFORMATION
%%% ----------------------------------------------------------
%%% %CCaseFile:	regBucket.erl %
%%% Author:	etxpell
%%% Description: A leaky bucket used for regulating spontaneous delets
%%%	and PBX commands towargds core network
%%%
%%% Modules used:    
%%%
%%% ----------------------------------------------------------

-module(sysRate).
-id('39/190 55-CNA 113 206 Ux').
-vsn('/main/R6A_1/R9B/R10A/R12A/R14A/R15A/R18A/R19A/3').

%%% ----------------------------------------------------------
%%% %CCaseTemplateFile:	module.erl %
%%% %CCaseTemplateId: 53/002 01-LXA 119 334 Ux, Rev: /main/5 %
%%%
%%% %CCaseCopyrightBegin%
%%% Copyright (c) Ericsson AB 2008-2012 All rights reserved.
%%% 
%%% The information in this document is the property of Ericsson.
%%% 
%%% Except as specifically authorized in writing by Ericsson, the 
%%% receiver of this document shall keep the information contained 
%%% herein confidential and shall protect the same in whole or in 
%%% part from disclosure and dissemination to third parties.
%%% 
%%% Disclosure and disseminations to the receivers employees shall 
%%% only be made on a strict need to know basis.
%%% %CCaseCopyrightEnd%
%%%
%%% ----------------------------------------------------------
%%% #1.    REVISION LOG
%%% ----------------------------------------------------------
%%% Rev    Date        Name     What
%%% -----  ----------  -------  ------------------------
%%%
%%% ----------------------------------------------------------


%% API
-export([define/2]).
-export([is_request_allowed/1]).
-export([status/1]).

-export([on/1]).
-export([off/1]).
-export([clear/1]).
-export([list_all_limiters/0]).
-export([print_all_limiters/0]).
-export([is_below_limit/1]).


define(Name, Config) -> call({define, Name, Config}).


call    



-export([check_rate/1]).

%% The core rate limiter
-export([rate_enqueue/0]).
-export([set_core_rate/1]).
-export([set_core_rate_burst_size/1]).
-export([set_core_rate_period/1]).
-export([reset_core_rate/0]).
-export([get_core_rate_config/0]).


-export([set_config/3]).
-export([get_config/0]).
-export([del_config/0]).


-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(ONE_MORE_MAX, 200).

-record(state, {one_more_c=?ONE_MORE_MAX, rate_bucket}).

-record(regBucket, {key, pid, msg, netid, role, local, 
		    spare1, spare2, spare3}).

-record(regRateBucket,
	{mode=off, level=0, leak_per_second=0, period=100, 
	 leak_ts=micro_ts(), auto_burst=true, burst_limit=0, 
	 timer, spare1, spare2}).


-define(TAB, regBucket).

-include("reg.hrl").

f() ->
    do_stuff(),
    case sysRate:allow_request(Key) of
    	 true -> do_more_stuff();
	 _ -> reject
    end.

f() ->
    do_stuff(),
    case sysRate:check_rate(Key) of
    	 true -> do_more_stuff();
	 _ -> reject
    end.

f() ->
    do_stuff(),
    case sysRate:allow(Key) of
    	 true -> do_more_stuff();
	 _ -> reject
    end.



%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------



enqueue(Key, NetId, Role, Local, Msg) ->
    call({enqueue, #regBucket{key=Key, pid=self(), msg=Msg,
			      netid=NetId, role=Role, local=Local}}).


cancel(Key) ->
    call({cancel, Key}).

leak_one_more() ->
    call(leak_one_more).

clear() ->
    ets:delete_all_objects(?TAB).


call(Cmd) ->
    gen_server:call(?MODULE, Cmd, 60000).


is_empty() -> 0 == ets:info(regBucket, size).


%% The core rate limiter
rate_enqueue() -> 
    call({core_rate, allow}).
set_core_rate(Rate) when (Rate>0) -> 
    call({core_rate, {set_rate, Rate}}).
set_core_rate_burst_size(Burst) when (Burst>0) -> 
    call({core_rate, {set_burst_size, Burst}}).
set_core_rate_period(Time) when (Time=<1000), (Time>9) -> 
    call({core_rate, {set_period, Time}}).
reset_core_rate() ->  
    call({core_rate, reset}).
get_core_rate_config() ->  
    call({core_rate, get_config}).

set_core_rate_stuff(Time, Rate) when Time < 1000 ->
    case catch round((1000/Time)*Rate) of
	LeakPerSecond when is_integer(LeakPerSecond) ->
	    set_core_rate(LeakPerSecond),
	    set_core_rate_period(Time),
	    core_rate_set;
	_ ->
	    core_rate_not_set
    end.
	    

%%====================================================================
%% gen_server callbacks
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    T = get_interval(), %%regLib:lookup_config(bucket_interval, 100),
    erlang:send_after(T, self(), leak),
    {ok, #state{rate_bucket=init_core_rate()}}.


%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(Req, _From, State) ->
    try
	handle_call2(Req, _From, upgrade_state(State))
    catch
	_:_Err ->
	    ?ERRDBG("handle call crashed", _Err),
	    {reply, error, State}
    end.

handle_call2({core_rate, Cmd}, _From, State) ->
    do_core_rate_cmd(Cmd, State);
handle_call2({enqueue, B}, _From, State) ->
    {reply, q_enqueue(B), State};
handle_call2({cancel, Key}, _From, State) ->
    {reply, q_cancel(Key), State};
handle_call2(leak_one_more, _From, State=#state{one_more_c=C})
  when C < 0 ->
    ?ERRDBG("leak_one_more, rate limit", []),
    {reply, ok, State};
handle_call2(leak_one_more, _From, State) ->
    ?DBG("leak_one_more", []),
    catch leak(1),
    {reply, ok, dec_one_more(State)}.


upgrade_state(S=#state{}) -> 
    S;
upgrade_state({state, OneMoreC}) ->
    #state{one_more_c=OneMoreC}.


%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, upgrade_state(State)}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(leak, State) ->
    T = try leak()
	catch
	    _:_ ->
		get_interval()
	end,
    erlang:send_after(T, self(), leak),
    {noreply, reset_one_more(upgrade_state(State))};
handle_info(core_rate_tick, State) ->
    {noreply, core_rate_leak(upgrade_state(State))};
handle_info(_Info, State) ->
    {noreply, upgrade_state(State)}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, upgrade_state(State)}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

leak() ->
    C = get_config(),
    leak_full(catch is_win_full(), C),
    update_rate(C),
    get_interval(C).

leak_full(true, _) -> 
    ?ERRDBG("window full, leak only 1", []),
    leak(1);
leak_full(_, C) ->
    N = get_leak(C),
    leak(N).
    




leak(N) ->
    leak(N, ets:first(?TAB)).


leak(0, _) ->
    ok;
leak(_, '$end_of_table') ->
    ok;
leak(N, K) ->
    leak2(N, K, ets:lookup(?TAB, K)).

leak2(N, K, [B=#regBucket{pid=Pid, msg=Msg}]) ->
    Next=ets:next(?TAB, K),
    q_dequeue(B),
    case erlang:process_info(Pid) of
	undefined ->
	    ?ERRCNT("de-reg window: proc dead", []),
	    leak(N, Next);
	_ ->
	    Pid ! Msg,
	    leak(N-1, Next)
    end;
leak2(_, _, _) ->
    ?ERRDBG("bad leaky bucket entry", []).

%% 	[#regBucket{pid=pid_entry}] ->
%% 	    %% Skip the pid backward reference entries
%% 	    Next=ets:next(?TAB, K),
%% 	    leak(N, Next);
%% 	[B=#regBucket{pid=Pid, msg=Msg}] ->
%% 	    Next=ets:next(?TAB, K),
%% 	    q_dequeue(B),
%% 	    Pid ! Msg,
%% 	    leak(N-1, Next);
%% 	_ ->
%% 	    ?ERRDBG("bad leaky bucket entry", [])
%%     end.


is_win_full() ->
    is_win_full2(ets:first(?TAB)).

is_win_full2('$end_of_table') ->
    false;
is_win_full2(K) ->
    case ets:lookup(?TAB, K) of
	[#regBucket{netid=NetId, role=Role, local=Local}] 
	when is_integer(NetId) ->
	    IpVsn = regLib:get_ip_vsn(Local),
	    CNw = regSgnI:get_nc(NetId, Role, IpVsn),
	    MaxWin = regSgnI:sip_throttling_win(CNw),
	    Curr = sipI:read_curr_win(Local),
%%%	    Curr = ets:update_counter( sip_counters, Local, {3, 0}),
%%	    ?DBG("sip throttling counters", [MaxWin, Curr]),
	    %% MaxWin is 0 if throttling is disabled
	    (Curr >= MaxWin) andalso (MaxWin /= 0);
	[_X] ->
	    false;
	_ ->
	    false
    end.

    



%%%--------------------------------------------------------------------
%%%
%%% q_enqueue/q_dequeue
%%%	Queue primitives
%%%
%%%--------------------------------------------------------------------

q_dequeue(#regBucket{key=Key, pid=Pid}) ->
    ets:delete(?TAB, Key),
    ets:delete(?TAB, Pid).

q_enqueue(B) ->
    true = ets:insert_new(?TAB, B),
%%%    ets:insert_new(?TAB, #regBucket{key=Pid, pid=pid_entry, msg=Key}),
    B.

q_cancel(Key) ->
    case ets:lookup(?TAB, Key) of
	[B] -> 
	    q_dequeue(B),
	    true;
	_ ->
	    false
    end.

%%%--------------------------------------------------------------------
%%%
%%% The rate limiter
%%%	Updated at each leak interval with fresh values
%%%
%%%--------------------------------------------------------------------
-define(REGBUCKETRATE, regBucketRate).
-define(REGBUCKETRATEDISABLE, 320000). %% Big enough to not limit
-define(REGBUCKETRATEOVRD, regBucketRateOvRd).


update_rate(C) ->
    catch update_rate2(get_rate(C)).

update_rate2(0) ->
    update_rate3(?REGBUCKETRATEDISABLE);
update_rate2(R) ->
    update_rate3(adj_rate(R, regLib:read_count(?REGBUCKETRATEOVRD))).

update_rate3(R) ->
    regLib:set_count(?REGBUCKETRATE, R),
    regLib:reset_count(?REGBUCKETRATEOVRD).
    

adj_rate(Rate, Forced) when Forced > Rate -> 0;
adj_rate(Rate, Forced) -> Rate - Forced.


rate_limit_allow(OverRide) ->
    rate_limit_allow(regLib:dec_count(?REGBUCKETRATE), OverRide).

rate_limit_allow(N, true) when N < 0 -> 
    ?ERRDBG("rate_limit_override", []),
    regLib:inc_count(?REGBUCKETRATEOVRD),
    true;
rate_limit_allow(N, _) when N < 0 -> 
    ?ERRDBG("rate_limit", []),
    false;
rate_limit_allow(_, _) ->
    true.



dec_one_more(S=#state{one_more_c=C}) -> S#state{one_more_c=C-1}.
reset_one_more(S) -> S#state{one_more_c=?ONE_MORE_MAX}.


%% -----------------------------
%% START OF core rate

init_core_rate() ->
    start_core_rate_timer(read_core_rate_config()).


do_core_rate_cmd(Cmd, S=#state{rate_bucket=Bucket}) ->
    {Res, NewBucket} = do_core_rate_cmd2(Cmd, assure_bucket(Bucket)),
    {reply, Res, S#state{rate_bucket=NewBucket}}.


do_core_rate_cmd2(allow, B) ->
    core_rate_allow(B);
do_core_rate_cmd2({set_rate, Rate}, B) ->
    NewB = B#regRateBucket{mode=on, leak_per_second=Rate},
    core_rate_config_change(NewB);
do_core_rate_cmd2({set_period, Time}, B) ->
    NewB = B#regRateBucket{period=Time},
    core_rate_config_change(NewB);
do_core_rate_cmd2(reset, B) ->
    cancel_core_rate_timer(B),
    core_rate_config_change(core_rate_bucket_new());
do_core_rate_cmd2(get_config, B) ->
    {pretty_format(B), B};
do_core_rate_cmd2({set_burst_size, Burst}, B) ->
    core_rate_config_change(B#regRateBucket{auto_burst=false, 
					    burst_limit=Burst}).

core_rate_config_change(B) ->
    NewB = 
	seq(B,
	    [fun cancel_core_rate_timer/1,
	     fun calc_auto_burst/1,
	     fun save_core_rate_config/1,
	     fun start_core_rate_timer/1]),
    {ok, NewB}.


core_rate_allow(B=#regRateBucket{mode=off}) ->
    ?ERRCNT("rate bucket allow: off", []),
    ?DBG("rate allow", {core_rate_allow, off}),
    {true, B};
core_rate_allow(B=#regRateBucket{level=Level, burst_limit=Lim})
  when (Level < Lim) ->
    ?ERRCNT("rate bucket allow: true", []),
    ?DBG("rate allow", {core_rate_allow, Level}),
    {true, B#regRateBucket{level=Level+1}};
core_rate_allow(B) ->
    ?ERRDBG("rate bucket allow: false", []),
    {false, B}.


%%-------------------
%% The leaking
core_rate_leak(S=#state{rate_bucket=Bucket}) ->
    S#state{rate_bucket=start_core_rate_timer(core_rate_leak(Bucket))};
core_rate_leak(B=#regRateBucket{level=Level}) ->
    NewTS = micro_ts(),
    Leak = calc_leak(NewTS, B),
    NewLevel = max((Level-Leak), 0),
    if Level == 0 ->	?DBG("leak: noa", []);
       true ->		?DBG("leak", [{leak, Leak}, {newLevel, NewLevel}])
    end,
    B#regRateBucket{leak_ts=NewTS, level=NewLevel}.

calc_leak(NewTS, #regRateBucket{leak_ts=OldTS, leak_per_second=LPS}) ->
    %% adjust for wrap
    ?DBG("timestamps", [{ts, OldTS}, {newts, NewTS}]),
    AdjustedNewTS = if OldTS > NewTS -> NewTS+1000000-OldTS;
		       true -> NewTS
		    end,
    LeakedSoFar = if OldTS > NewTS -> 0;
		     true -> round(OldTS*LPS/1000000)
		  end,

    LeakUpTillNewTS = round(AdjustedNewTS*LPS/1000000),
    
    LeakUpTillNewTS - LeakedSoFar.


%%-------------------
%% Calculating stuff as a result of reconfig
%% calc_leak_per_period(B=#regRateBucket{leak_per_second=Leak, period=Period}) ->
%%     LeakPerPeriod = round(Period*Leak/1000),
%%     B#regRateBucket{leak_per_period=LeakPerPeriod}.

calc_auto_burst(B=#regRateBucket{auto_burst=true, leak_per_second=Leak}) ->
    B#regRateBucket{burst_limit=Leak};
calc_auto_burst(B) ->
    B.


%% -----------------------------
%% timer stuff

start_core_rate_timer(B=#regRateBucket{mode=on, period=Time}) ->
    B#regRateBucket{timer=do_timer_start(Time, core_rate_tick)};
start_core_rate_timer(B) ->
    B.

cancel_core_rate_timer(B=#regRateBucket{timer=T}) ->
    do_timer_cancel(T),
    B#regRateBucket{timer=undefined}.



do_timer_start(Time, Msg) ->
    erlang:send_after(Time, self(), Msg).

do_timer_cancel(T) when is_reference(T) ->
    erlang:cancel_timer(T);
do_timer_cancel(_) ->
    ok.
    

%% -----------------------------
%% timestamp primitives
micro_ts() ->
    element(3, ts()).
ts() ->
    os:timestamp().


%% -----------------------------
%% Pretty formating of bucket record
pretty_format(B) when is_record(B, regRateBucket) ->
    lists:zip(record_info(fields, regRateBucket), tl(tuple_to_list(B))).


%% -----------------------------
%% core rate configuration

assure_bucket(B=#regRateBucket{}) -> B;
assure_bucket(_) -> read_core_rate_config().

read_core_rate_config() ->
    case sysTabRead(core_rate_config) of
	Res=#regRateBucket{} -> Res;
	_ -> core_rate_bucket_new()
    end.

save_core_rate_config(Conf) ->
    sysTabWrite(core_rate_config, Conf),
    Conf.

%% remove_core_rate_config() ->
%%     sysTabDelete(core_rate_config).

sysTabRead(Key) ->
    sysTab:dirty_read({?MODULE, Key}).
sysTabWrite(Key, Val) ->
    sysTab:dirty_write({?MODULE, Key}, Val).
%% sysTabDelete(Key) ->
%%     sysTab:dirty_delete({?MODULE, Key}).

core_rate_bucket_new() ->
    #regRateBucket{}.


%%-------------------
%% Run a number of functions sequentially.
seq(Err={error, _}, _) ->
    Err;
seq(Data, [H|R]) ->
    seq(H(Data), R);
seq(Data, []) ->
    Data.


%% -----------------------------
%% END OF core rate


%%%--------------------------------------------------------------------
%%%
%%% Configuration primitives
%%%
%%%--------------------------------------------------------------------

get_interval() -> get_interval(get_config()).

get_interval(C) -> get_conf_item(1, C, 200).
get_leak(C) -> get_conf_item(3, C, 20).
get_rate(C) -> get_conf_item(5, C, 0).


get_conf_item(Ix, T, _Def) when size(T) == 5 ->
    element(Ix, T);
get_conf_item(_, _, Def) ->
    Def.

%% Set the config.
%%	Time - number of ms between bucket/rate polls
%%	Leak - Leak rate (in items/second)
%%	Rate - Rate limit (in items/second)
set_config(Time, Leak, Rate) ->
    mnesia:transaction(
      fun() -> 
	      T = {Time, 
		   Leak, Leak, %%per_time(Time, Leak),
		   Rate, Rate}, %%per_time(Time, Rate)},
	      sgnI:sgcRegBucket(set, T)
      end),
    set_core_rate_stuff(Time, Rate).

%%per_time(Time, X) -> round(Time/1000*X).

get_config() ->
    case sgnI:sgcRegBucket(get, dirty) of
	T when size(T) == 5 ->
	    T;
	_ ->
	    undefined
    end.

%% ONLY FOR TESTING!!!
del_config() ->
    mnesia:transaction(fun() -> mnesia:delete({sgmParam, sgcRegBucket}) end).




