// /* eslint-disable node/no-missing-import */
// /* eslint-disable node/no-unsupported-features/es-builtins */
// /* eslint-disable prettier/prettier */
// import { expect } from "chai";
// import { ethers } from "hardhat";
// import { randomAddress, genMTree } from "../utils"
// import data from "../data/data.json"

// let deployer:any, addrs: any, root:any, tree:any, paradox:any, presale:any;

// describe("Claims tests", async () => {
//     beforeEach(async function () {
//       [deployer, ...addrs] = await ethers.getSigners();
//       // generate the tree
//       [tree, root] = genMTree(data)

//       paradox = await ethers.getContractFactory("Paradox")
//       paradox = await paradox.deploy()
      
//       // SEED PRESALE CONTRACT
//       // TODO, instantiate Tether and NFTs address
//       presale = await ethers.getContractFactory("NFTPresale");
//       presale = await presale.deploy()

//       // Add root to contract
//       await presale.updateRoot(root);
//     });
//     it("Should be able to claim", async () => {
//       const { leaf, address, amount } = randomAddress(data);
//       const proof = tree.getHexProof(leaf);

//       expect(await presale.canClaim(address, amount, proof)).to.equal(true);

//       await presale.claimGenius(address, amount, proof);

//       expect((await presale.balanceOf(address)).toString()).to.equal(
//         amount.toString()
//       )
//   });
//   it("Cannot claim twice", async () => {})
//   // check numbers below
//   it("Claims and then the full vesting cycle is completed", async () => {})
//   it("Claims and a new merkle root is added, can no longer claim under any circumstances", async () => {})
//   // for this one, just add a hardhat wallet public key to the data and a number amount in the field
//   it("Claims and a new merkle root is added, new additions can claim", async () => {})

// });