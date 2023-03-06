async function main() {
  const vaultAddress = "0xd072Fa5E4a19705d14FF02942088118eD6aeFBe5";
  const strategyAddress = "0x8931f204107D43299FE0dD483C68F5c62A13bEd0";

  const Vault = await ethers.getContractFactory("ReaperVaultv1_3");
  const vault = Vault.attach(vaultAddress);

  //const options = { gasPrice: 2000000000000, gasLimit: 9000000 };
  await vault.initialize(strategyAddress);
  console.log("Vault initialized");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
