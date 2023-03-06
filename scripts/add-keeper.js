const hre = require("hardhat");

async function main() {
  const stratAddress = "0xD3BF27E1606dF8Ac80f4Fd3c4faF47b8c31a1021";
  const Strat = await ethers.getContractFactory("ReaperAutoCompoundXBoov2");
  const keeperAddress = "0x9ccA5c3829224F7ac9077540bC365De4384823A7";
  const strat = await Strat.attach(stratAddress);
  await strat.grantRole("0x71a9859d7dd21b24504a6f306077ffc2d510b4d4b61128e931fe937441ad1836",keeperAddress);
  console.log("Boo approved");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
