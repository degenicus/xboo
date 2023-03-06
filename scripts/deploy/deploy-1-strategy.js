async function main() {
    const vault = "0xFC550BAD3c14160CBA7bc05ee263b3F060149AFF"
    const strategist1 = "0x1E71AEE6081f62053123140aacC7a06021D77348";
    const strategist2 = "0x81876677843D00a7D792E1617459aC2E93202576";
    const strategist3 = "0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4";
    const strategist4 = "0x60BC5E0440C867eEb4CbcE84bB1123fad2b262B1";
    const treasuryAddress = "0x0e7c5313E9BB80b654734d9b7aB1FB01468deE3b";
    const superAdminMultisig = "0x04C710a1E8a738CDf7cAD3a52Ba77A784C35d8CE";
    const AdminMultisig = "0x539eF36C804e4D735d8cAb69e8e441c12d4B88E0";
    const GaurdianMultisig = "0xf20E25f2AB644C8ecBFc992a6829478a85A98F2c";

    // get artifacts
    const ReaperAutoCompoundXBoov2 = await ethers.getContractFactory('ReaperAutoCompoundXBoov2');

    reaperAutoCompoundXBoov2 = await hre.upgrades.deployProxy(
        ReaperAutoCompoundXBoov2,
        [
            vault, //vault
            [treasuryAddress, treasuryAddress], //feeRemitters
            [strategist1,strategist2,strategist3,strategist4],//strategists
            [superAdminMultisig,AdminMultisig,GaurdianMultisig]//multisigRoles
        ],
        {kind: 'uups'},
    );
    await reaperAutoCompoundXBoov2.deployed();

    console.log('ReaperAutoCompoundXBoov2 deployed to:', reaperAutoCompoundXBoov2.address);
}
  
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });