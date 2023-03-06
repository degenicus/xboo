const hre = require("hardhat");

async function main() {
  const Strategy = await ethers.getContractFactory("ReaperAutoCompoundXBoo");
  const PaymentRouter = await ethers.getContractFactory("PaymentRouter");
  const Vault = await ethers.getContractFactory("ReaperVaultv1_3");

  const booAddress = "0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE";
  const tokenName = "XBOO Single Stake Vault";
  const tokenSymbol = "rfXBOO";
  const approvalDelay = 432000;
  const depositFee = 0;
  const tvlCap = ethers.utils.parseEther("33");

  const vault = await Vault.deploy(
    booAddress,
    tokenName,
    tokenSymbol,
    approvalDelay,
    depositFee,
    tvlCap
  );

  await vault.deployed();
  console.log("Vault deployed to:", vault.address);

  const treasuryAddress = "0x0e7c5313E9BB80b654734d9b7aB1FB01468deE3b";
  const paymentRouterAddress = "0x603e60d22af05ff77fdcf05c063f582c40e55aae";
  const strategist1 = "0x1E71AEE6081f62053123140aacC7a06021D77348";
  const strategist2 = "0x81876677843D00a7D792E1617459aC2E93202576";
  const strategist3 = "0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4";

  const strategy = await Strategy.deploy(
    vault.address,
    [treasuryAddress, paymentRouterAddress],
    [strategist1, strategist2, strategist3]
  );

  await strategy.deployed();
  console.log("Strategy deployed to:", strategy.address);

  const strategistFeeReceiver = "0x81876677843D00a7D792E1617459aC2E93202576";

  const paymentRouter = await PaymentRouter.attach(paymentRouterAddress);
  await paymentRouter.addStrategy(
    strategy.address,
    [strategistFeeReceiver],
    [10000]
  );
  console.log("Strategy added to payment router");

  const WFTM_ID = 2;
  const FOO_ID = 3;
  const WFTM = "0x21be370d5312f44cb42ce377bc9b8a0cef1a4c83";
  const FOO = "0xFbc3c04845162F067A0B6F8934383E63899c3524";

  const tx1 = await strategy.addUsedPool(WFTM_ID, [WFTM, WFTM]);
  const tx2 = await strategy.addUsedPool(FOO_ID, [FOO, WFTM]);
  await tx1.wait();
  await tx2.wait();
  console.log("Pools added to strategy");

  await vault.initialize(strategy.address);
  console.log("Vault initialized");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
