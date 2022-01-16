async function main() {
  const vaultAddress = "0x65bbD82baF32aAF96d82081b2eB332f8A76F5058";
  const strategyAddress = "0x3d64A3cAC844cB19a4E34f20FCFCaDEf79aB7e24";

  const Vault = await ethers.getContractFactory("ReaperVaultv1_3");
  const vault = Vault.attach(vaultAddress);

  const options = { gasPrice: 2000000000000, gasLimit: 9000000 };
  await vault.initialize(strategyAddress, options);
  console.log("Vault initialized");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });