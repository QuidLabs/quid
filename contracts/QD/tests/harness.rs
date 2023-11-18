use fuels::{prelude::*, types::ContractId};
 
// Load abi from json
abigen!(Contract, "./out/debug/QD-abi.json");
 
async fn get_contract_instance() -> (Contract, ContractId) {
	// Launch a local network and deploy the contract
	let mut wallets = launch_custom_provider_and_get_wallets(
		WalletsConfig::new(
			Some(1),			 /* Single wallet */
			Some(1),			 /* Single coin (UTXO) */
			Some(1_000_000_000), /* Amount per coin */
		),
		None,
	)
	.await;
	let wallet = wallets.pop().unwrap();
 
	let id = Contract::load_from(
		"./out/debug/QD.bin",
		LoadConfiguration::default().set_storage_configuration(
			StorageConfiguration::load_from(
				"./out/debug/QD-storage_slots.json",
			)
			.unwrap(),
		),
	)
	.unwrap()
	.deploy(&wallet, TxParameters::default())
	.await
	.unwrap();
 
	let instance = Contract::new(id.to_string(), wallet);
 
	(instance, id.into())
}
 
#[tokio::test]
async fn initialize_and_increment() {
	let (contract_instance, _id) = get_contract_instance().await;
	// Now you have an instance of your contract you can use to test each function
 
	// let result = contract_instance
	// 	.methods()
	// 	.initialize_counter(42)
	// 	.call()
	// 	.await
	// 	.unwrap();
 
	// assert_eq!(42, result.value);
 
	// // Call `increment_counter()` method in our deployed contract.
	// let result = contract_instance
	// 	.methods()
	// 	.increment_counter(10)
	// 	.call()
	// 	.await
	// 	.unwrap();
 
	// assert_eq!(52, result.value);
}