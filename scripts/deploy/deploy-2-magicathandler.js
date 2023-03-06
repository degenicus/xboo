async function main() {
  const vaultAddress = '0xFC550BAD3c14160CBA7bc05ee263b3F060149AFF';
  const strategyAddress = '';
  const strategist1 = '0x1E71AEE6081f62053123140aacC7a06021D77348';
  const strategist2 = '0x81876677843D00a7D792E1617459aC2E93202576';
  const strategist3 = '0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4';
  const strategist4 = '0x60BC5E0440C867eEb4CbcE84bB1123fad2b262B1';
  const superAdminMultisig = '0x04C710a1E8a738CDf7cAD3a52Ba77A784C35d8CE';

  // get artifacts
  const MagicatsHandlerUpgradeable = await ethers.getContractFactory('MagicatsHandlerUpgradeable');

  const magicatsHandlerUpgradeable = await hre.upgrades.deployProxy(
    MagicatsHandlerUpgradeable,
    [
      strategyAddress,
      vaultAddress,
      [strategist1, strategist2, strategist3, strategist4], //strategists
      [superAdminMultisig], //multisigRoles
    ],
    {kind: 'uups'},
  );

  await magicatsHandlerUpgradeable.deployed();

  console.log('MagicatsHandlerUpgradeable deployed to:', magicatsHandlerUpgradeable.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
