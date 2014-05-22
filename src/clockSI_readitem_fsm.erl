%% @doc The coordinator for stat write opeartions.  This example will
%% show how to properly replicate your data in Riak Core by making use
%% of the _preflist_.
-module(clockSI_readitem_fsm).
-behavior(gen_fsm).
-include("floppy.hrl").

%% API
-export([start_link/6]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([check_clock/2,
	 get_txs_to_check/2,
	 commit_notification/2, 
	 return/2]).

%% Spawn

-record(state, {type,
		key,
	 	tx_id,
		tx_coordinator,
		vnode,
		updates,
		pending_txs}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Vnode, Coordinator, Tx, Key, Type, Updates) ->
    gen_fsm:start_link(?MODULE, [Vnode, Coordinator, Tx, Key, Type, Updates], []).

now_milisec({MegaSecs,Secs,MicroSecs}) ->
	(MegaSecs*1000000 + Secs)*1000000 + MicroSecs.
%%%===================================================================
%%% States
%%%===================================================================

init([Vnode, Coordinator, TxId, Key, Type, Updates]) ->
    SD = #state{
		vnode=Vnode,
		type=Type,
		key=Key,
                tx_coordinator=Coordinator, 
                tx_id=TxId,
		updates=Updates,
		pending_txs=[]},
    {ok, check_clock, SD, 0}.

%% @doc check_clock: Compares its local clock with the tx timestamp.
%%	if local clock is behinf, it sleeps the fms until the clock
%%	catches up. CLOCK-SI: clock scew.
check_clock(timeout, SD0=#state{tx_id=TxId}) ->
    T_TS = TxId#tx_id.snapshot_time,
    Time = now_milisec(erlang:now()),
    case (T_TS) > Time of true ->
    	io:format("ClockSI ReadItemFSM: waiting for clock to catchUp ~n"),
		timer:sleep(T_TS - Time),	
		io:format("ClockSI ReadItemFSM: done waiting... ~n"),
		{next_state, get_txs_to_check, SD0, 0};
		
	false ->
		io:format("ClockSI ReadItemFSM: no need to wait for clock to catchUp ~n"),
		{next_state, get_txs_to_check, SD0, 0}
    end.		
%% @doc get_txs_to_check: 
%%	- Asks the Vnode for pending txs conflicting the cyrrent one
%%	- If none, goes to return state
%%	- Otherwise, goes to commit_notification
get_txs_to_check(timeout, SD0=#state{tx_id=TxId, vnode=Vnode, key=Key}) ->
	io:format("ClockSI ReadItemFSM: Calling vnode ~w to get pending txs for Key ~w ~n", [Vnode, Key]),
    case clockSI_vnode:get_pending_txs(Vnode, {Key, TxId}) of
    {ok, empty} ->		
    	io:format("ClockSI ReadItemFSM: no txs to wait for ~w ~n", [Key]),
		{next_state, return, SD0, 0};
    {ok, Pending} ->
    	%{Committing, Pendings} = pending_commits(T_snapshot_time, Txprimes),
    	io:format("ClockSI ReadItemFSM: txs to wait for ~w. Pendings ~w~n", [Key, Pending]),
        {next_state, commit_notification, SD0=#state{pending_txs=Pending}, 0};
    {error, _Reason} ->
        io:format("ClockSI ReadItemFSM: error while retrieving pending txs for Key: ~w ~n", [Key]),
		{stop, normal, SD0}
    end.

%% @doc commit_notification:
%%	- The fsm stays in this state until the list of pending txs is empty.
%%	- The commit notifications are sent by the vnode.
commit_notification({committed, TxId}, SD0=#state{pending_txs=Left}) ->
    Left2=lists:delete(TxId, Left),
    io:format("ClockSI ReadItemFSM: tx ~w has committed ~n", [TxId]),
    case Left2 of [] ->
		io:format("ClockSI ReadItemFSM: no further txs to wait for"),
    	{next_state, return, SD0=#state{pending_txs=Left2}, 0};
    [H|T] ->
    	io:format("ClockSI ReadItemFSM: still waiting for txs ~w ~n", [Left2]),
    	{next_state, commit_notification, SD0=#state{pending_txs=[H|T]}};
    _-> 
    	io:format("ClockSI ReadItemFSM: tx ~w has committed ~n", [TxId])
    end.

%% @doc	return:
%%	- Reads adn retunrs the log of the specified Key using the replication layer.
return(timeout, SD0=#state{tx_coordinator=Coordinator, tx_id= TxId, key=Key, type=Type, updates=Updates}) ->
	io:format("ClockSI ReadItemFSM: reading key ~w ~n", [Key]),
    case floppy_rep_vnode:read(Key, Type) of
    {ok, Ops} ->
    	io:format("ClockSI ReadItemFSM: got the operations for key ~w, calling the materializer... ~n", [Key]),
	Init=clockSI_materializer:create_snapshot(Type),
    	Snapshot=clockSI_materializer:update_snapshot(Type, Init, TxId#tx_id.snapshot_time, Ops),
	Updates2=filter_updates_per_key(Updates, Key),
	io:format("Filtered updates before completeing the read: ~w ~n" , [Updates2]),
	Snapshot2=clockSI_materializer:update_snapshot_eager(Type, Snapshot, Updates2),
	Reply=Type:value(Snapshot2),
	%Reply = clockSI_materializer:materialize(Type, TxId#tx_id.snapshot_time, Ops),
	io:format("ClockSI ReadItemFSM: finished materializing");
    _ ->
    	io:format("ClockSI ReadItemFSM: reading from the replication group has returned an unexpected response ~n"),
	Reply=error
    end,
    io:format("ClockSI ReadItemFSM: replying to the tx coordinator ~w ~n", [Coordinator]),
    riak_core_vnode:reply(Coordinator, Reply),
    io:format("ClockSI ReadItemFSM: finished fsm for key ~w ~n", [Key]),
    {stop, normal, SD0}.

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%Internal functions

filter_updates_per_key(Updates, Key) ->
    int_filter_updates_key(Updates, Key, []).

int_filter_updates_key([], _Key, Updates2) ->
    Updates2;

int_filter_updates_key([Next|Rest], Key, Updates2) ->
    {_, {KeyPrime, Op}} = Next,
    io:format("Comparing keys ~w==~w~n",[KeyPrime, Key]),
    case KeyPrime==Key of
    true ->
	int_filter_updates_key(Rest, Key, lists:append(Updates2, [Op]));
    false ->	    
	int_filter_updates_key(Rest, Key, Updates2)
    end.
