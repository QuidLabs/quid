use fuels::{
    accounts::wallet::WalletUnlocked,
    types::{
        ContractId, Identity, 
    },
    prelude::{ abigen, Contract, Config,
        CallParameters,
        AssetConfig, AssetId, Bech32Address,
        LoadConfiguration, StorageConfiguration, 
        TxParameters, WalletsConfig, BASE_ASSET_ID,
        launch_custom_provider_and_get_wallets,
        setup_single_asset_coins, setup_test_provider,
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
const STORAGE_CONFIGURATION_PATH: &str = "out/debug/QD-storage_slots.json";
const CONTRACT_BIN_PATH: &str = "out/debug/QD.bin";

pub(crate) struct User {
    pub(crate) contract: QD<WalletUnlocked>,
    pub(crate) wallet: WalletUnlocked,
}

pub(crate) fn base_asset_contract_id() -> ContractId {
    ContractId::new(BASE_ASSET_ID.try_into().unwrap())
}

// This function will setup the test environment for you. It will return a tuple containing the contract instance and the script instance.
pub async fn setup() -> (User, User) {
    let number_of_coins = 2;
    let coin_amount = 1_000_000_000_000;
    let number_of_wallets = 3;
    let base_asset = AssetConfig {
        id: BASE_ASSET_ID,
        num_coins: number_of_coins,
        coin_amount,
    };
    // Random asset for making sure that depositing it doesn't work
    // only BASE_ASSET (ETH) is able to be deposited 
    let asset_id = AssetId::new([1; 32]);
    let asset = AssetConfig {
        id: asset_id,
        num_coins: number_of_coins,
        coin_amount,
    };
    let assets = vec![base_asset, asset];
    let wallet_config = WalletsConfig::new_multiple_assets(number_of_wallets, assets);

    let provider_config = Config {
        manual_blocks_enabled: true,
        ..Config::local_node()
    };
    let mut wallets =
        launch_custom_provider_and_get_wallets(wallet_config, Some(provider_config), None).await;

    let deployer_wallet = wallets.pop().unwrap();
    let depositor_wallet = wallets.pop().unwrap();
    let borrower_wallet = wallets.pop().unwrap();    

    // TODO why does this throw compile error (not function called load_from found)
    // let storage_configuration =
    //     StorageConfiguration::load_from(STORAGE_CONFIGURATION_PATH);
    let configuration = LoadConfiguration::default();
        // .set_storage_configuration(storage_configuration.unwrap());
        // ^ throws compile error (suggesting with_storage_configuration)
    let quid_id = 
        Contract::load_from(CONTRACT_BIN_PATH, configuration)           
            .unwrap()
            .deploy(&deployer_wallet, TxParameters::default())
            .await
            .unwrap();

    let depositor = User {
        contract: QD::new(quid_id.clone(), depositor_wallet.clone()),
        wallet: depositor_wallet.clone(),
    };
    let borrower = User {
        contract: QD::new(quid_id.clone(), borrower_wallet.clone()),
        wallet: borrower_wallet.clone(),
    };

    (depositor, borrower)
}

#[tokio::test]
async fn test_set_price() {  // test set price and get price to make sure storage works
    // Call the setup function to deploy the contract and create the contract instance
    let (depositor, borrower) = setup().await;

    depositor.contract
        .methods()
        .set_price(42)
        .call()
        .await
        .unwrap();

    let result = depositor.contract
        .methods()
        .get_price()
        .call()
        .await
        .unwrap().value;

    assert_eq!(result, 42);
}

#[tokio::test]
async fn test_deposit_withdraw() {
    // Call the setup function to deploy the contract and create the contract instance
    let (depositor, borrower) = setup().await;
    
    let params = CallParameters::new(42, BASE_ASSET_ID, 3000); // 3k is gas
    
    let res = depositor.contract
        .methods()
        .deposit(true, true) // TODO FALSE POSITIVE! i'm passing in true, but it goes into false leg
        .call_params(params)
        .unwrap()
        .call()
        .await
        .unwrap()
        .decode_logs_with_type::<u64>().unwrap();
    assert_eq!(res, vec![54]); // this should not be happening !
    
    // let result = depositor.contract
    //     .methods()
    //     .get_live()
    //     .call()
    //     .await
    //     .unwrap();
   
    let address = depositor.wallet.address();
    // let result = depositor.contract
    //     .methods()
    //     .get_pledge_live(address)
    //     .call()
    //     .await
    //     .unwrap()
    //     //.decode_logs();
    //     .decode_logs_with_type::<u64>().unwrap();
    // assert_eq!(result, vec![69]);
    

    // println!("credit @ {:?}", result.unwrap);
    // println!("debit {0}", pod.debit);
}

