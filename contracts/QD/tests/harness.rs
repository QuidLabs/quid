use fuels::{
    prelude::{abigen, Config, Contract, LoadConfiguration, StorageConfiguration, TxParameters},
    types::{errors::Result, Bits256},
    programs::contract::SettableContract,
    test_helpers::launch_provider_and_get_wallet,
    accounts::wallet::WalletUnlocked,
};


#[tokio::test]
async fn contract_call() -> Result<()> {
    use fuels::prelude::*;

    abigen!(Contract(
        name = "Quid",
        abi = "contracts/QD/out/debug/QD-abi.json"
    ));

    let wallet = launch_provider_and_get_wallet().await;

    let contract_id = Contract::load_from(
        "contracts/QD/out/debug/QD.bin",
        LoadConfiguration::default(),
    )?
    .deploy(&wallet, TxParameters::default())
    .await;

    // ANCHOR: contract_call_cost_estimation
    let contract_instance = Quid::new(contract_id, wallet);

    Ok(())
}