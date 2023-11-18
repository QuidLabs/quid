use fuels::{
    accounts::wallet::WalletUnlocked,
    types::ContractId,
    prelude::{
        abigen, Contract, 
        LoadConfiguration, 
        StorageConfiguration, 
        TxParameters
    },
    programs::contract::SettableContract,
    test_helpers::launch_provider_and_get_wallet,
};

// The following macro will automatically generate some structs for you, to easily interact with contracts and scripts.
abigen!(
    Contract(
        name = "QD",
        abi = "contracts/QD/out/debug/QD-abi.json"
    ),
);

// File path constants
const STORAGE_CONFIGURATION_PATH: &str =
    "out/debug/QD-storage_slots.json";
const CONTRACT_BIN_PATH: &str = "out/debug/QD.bin";


// This function will setup the test environment for you. It will return a tuple containing the contract instance and the script instance.
pub async fn setup() -> (
    QD<WalletUnlocked>
) {
    // The `launch_provider_and_get_wallet` function will launch a local provider and create a wallet for you.
    let wallet = launch_provider_and_get_wallet().await;

    // The following code will load the storage configuration (default storage values) from the contract and create a configuration object.
    // let storage_configuration =
    //     StorageConfiguration::load_from(STORAGE_CONFIGURATION_PATH).unwrap();
    // let configuration =
    //     LoadConfiguration::default().with_storage_configuration(storage_configuration);

    // The following code will deploy the contract and store the returned ContractId in the `id` variable.
    let id = Contract::load_from(
        CONTRACT_BIN_PATH, 
        LoadConfiguration::default(),
    ).unwrap()
    .deploy(&wallet, TxParameters::default())
    .await
    .unwrap();

    // Creates a contract instance and a script instance. Which allow for easy interaction with the contract and script.
    let contract_instance = QD::new(id, wallet.clone());

    (contract_instance)
}

#[tokio::test]
async fn test_script() {
    // Call the setup function to deploy the contract and create the contract instance
    let contract_instance = setup().await;
    // assert_eq!(result, 0);
}