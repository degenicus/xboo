// spiritWallet: 0x55a078AFC2e20C8c20d1aa4420710d827Ee494d4
// spookyWallet: 0x5241F63D0C1f2970c45234a0F5b345036117E3C2
// liquidWallet: 0xf58d534290Ce9fc4Ea639B8b9eE238Fe83d2efA6
// popsicleWallet: 0x5318250BD0b44D1740f47a5b6BE4F7fD5042682D
// hyperWallet: 0xa64A9687F7b37268d4043f2cBf23Be56d666696C
// wakaWallet: 0x33D6cB7E91C62Dd6980F16D61e0cfae082CaBFCA
// steakWallet: 0x51263D56ec81B5e823e34d7665A1F505C327b014
// alphaWallet: 0x87A5AfC8cdDa71B5054C698366E97DB2F3C2BC2f
// betaWallet: 0xe0268Aa6d55FfE1AA7A77587e56784e5b29004A2
// thetaWallet: 0x34Df14D42988e4Dc622e37dc318e70429336B6c5
// omegaWallet: 0x73C882796Ea481fe0A2B8DE499d95e60ff971663
// angieWallet: 0x36a63324edFc157bE22CF63A6Bf1C3B49a0E72C0
// arkyWallet: 0x9a2AdcbFb972e0EC2946A342f46895702930064F
// crowWallet: 0x7B540a4D24C906E5fB3d3EcD0Bb7B1aEd3823897
// birbWallet: 0x8456a746e09A18F9187E5babEe6C60211CA728D1
// noobWallet: 0xd21E0fE4ba0379Ec8DF6263795c8120414Acd0A3
// poopWallet: 0x9ccA5c3829224F7ac9077540bC365De4384823A7 <-- already keeper
// duckWallet: 0x2BDAaa2aeD043C473D2bA2AeABdF1A721417AB75
// bruceWallet: 0x87F3Cb66F773e7Ad8dB9c9B973E7D9684fa3D3a9

const hre = require('hardhat');

const upgradeProxy = async () => {
  const stratFactory = await ethers.getContractFactory('ReaperAutoCompoundXBoov2');
  await hre.upgrades.upgradeProxy(tusdProxy, stratFactory, { ...options, timeout: 0 });
  console.log('upgradeProxy');
};
async function main() {
  const proxyADDR = '0xD3BF27E1606dF8Ac80f4Fd3c4faF47b8c31a1021';
  const MagicatsHandlerUpgradeable = await ethers.getContractFactory('MagicatsHandlerUpgradeable');
  await hre.upgrades.upgradeProxy(proxyADDR, MagicatsHandlerUpgradeable);
  console.log("updated");

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
