//! API server handles endpoints for interaction with node.
//!
//! `mod rest` - api is used for block explorer.
//! `mod rpc_server` - JSON rpc via HTTP (for request reply functions)
//! `mod rpc_subscriptions` - JSON rpc via WebSocket (for request reply functions and subscriptions)

// External uses
use futures::channel::mpsc;
// Workspace uses
use models::{config_options::ConfigurationOptions, Operation};
use storage::ConnectionPool;
// Local uses
use crate::fee_ticker::TickerRequest;
use crate::{
    eth_watch::EthWatchRequest,
    mempool::MempoolRequest,
    signature_checker,
    state_keeper::{ExecutedOpsNotify, StateKeeperRequest},
    utils::current_zksync_info::CurrentZksyncInfo,
};

mod event_notify;
mod loggers;
mod ops_counter;
mod rest;
pub mod rpc_server;
mod rpc_subscriptions;

#[allow(clippy::too_many_arguments)]
pub fn start_api_server(
    op_notify_receiver: mpsc::Receiver<Operation>,
    connection_pool: ConnectionPool,
    panic_notify: mpsc::Sender<bool>,
    mempool_request_sender: mpsc::Sender<MempoolRequest>,
    executed_tx_receiver: mpsc::Receiver<ExecutedOpsNotify>,
    state_keeper_request_sender: mpsc::Sender<StateKeeperRequest>,
    eth_watcher_request_sender: mpsc::Sender<EthWatchRequest>,
    ticker_request_sender: mpsc::Sender<TickerRequest>,
    config_options: ConfigurationOptions,
    current_zksync_info: CurrentZksyncInfo,
) {
    let (sign_check_sender, sign_check_receiver) = mpsc::channel(8192);

    signature_checker::start_sign_checker_detached(
        sign_check_receiver,
        eth_watcher_request_sender.clone(),
        panic_notify.clone(),
    );

    rest::start_server_thread_detached(
        connection_pool.clone(),
        config_options.rest_api_server_address,
        config_options.contract_eth_addr,
        mempool_request_sender.clone(),
        eth_watcher_request_sender.clone(),
        panic_notify.clone(),
        config_options.clone(),
    );
    rpc_subscriptions::start_ws_server(
        &config_options,
        op_notify_receiver,
        connection_pool.clone(),
        mempool_request_sender.clone(),
        executed_tx_receiver,
        state_keeper_request_sender.clone(),
        sign_check_sender.clone(),
        eth_watcher_request_sender.clone(),
        ticker_request_sender.clone(),
        panic_notify.clone(),
        config_options.api_requests_caches_size,
        current_zksync_info.clone(),
    );

    rpc_server::start_rpc_server(
        config_options,
        connection_pool,
        mempool_request_sender,
        state_keeper_request_sender,
        sign_check_sender,
        eth_watcher_request_sender,
        ticker_request_sender,
        panic_notify,
        current_zksync_info,
    );
}
