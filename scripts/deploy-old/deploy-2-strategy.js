async function main() {
  const vaultAddress = "0xd072Fa5E4a19705d14FF02942088118eD6aeFBe5";

  const Strategy = await ethers.getContractFactory("ReaperAutoCompoundXBoo");
  const treasuryAddress = "0x0e7c5313E9BB80b654734d9b7aB1FB01468deE3b";
  const paymentRouterAddress = "0x603e60d22af05ff77fdcf05c063f582c40e55aae";
  const strategist1 = "0x1E71AEE6081f62053123140aacC7a06021D77348";
  const strategist2 = "0x81876677843D00a7D792E1617459aC2E93202576";
  const strategist3 = "0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4";

  // const options = { gasPrice: 2000000000000, gasLimit: 9000000 };
  const strategy = await Strategy.deploy(
    vaultAddress,
    [treasuryAddress, paymentRouterAddress],
    [strategist1, strategist2, strategist3]
  );

  await strategy.deployed();
  console.log("Strategy deployed to:", strategy.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
