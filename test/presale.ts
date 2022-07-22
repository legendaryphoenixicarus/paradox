/* eslint-disable node/no-unsupported-features/es-builtins */
/* eslint-disable prettier/prettier */
import { expect } from "chai";
import { MerkleTree } from "merkletreejs";
import { ethers, network } from "hardhat";

let para: any, usdt: any, presale: any;
let deployer: any, alice: any;
let merkleTree: any, root: any, proof: any;

// create proof
const usdtAmount = BigInt(500 * 10 ** 6);

const deployContract = async (contract: string, params: any[]) => {
	let con: any;
	const c = await ethers.getContractFactory(contract);
	if (params) con = await c.deploy(...params);
	else con = await c.deploy();
	return await con.deployed();
};

const deployContracts = async (_root: any) => {
	const para = await deployContract("ParadoxToken", []);
    const nft = await deployContract("Paradox", []);
    const usdt = await deployContract("USDT", []);
	const presale = await deployContract("NFTPresale", [
		usdt.address,
		nft.address,
		para.address,
        _root
	]);

	return {
		para,
		usdt,
        presale
	};
};

export const format = (amount: number, dec: number) => {
    return Number(Number(ethers.utils.formatUnits(amount, dec)).toFixed(6));
  };

export const parse = (amount: string, dec: number) => {
    return ethers.utils.parseUnits(amount, dec);
  };

describe("Presale", async () => {
    beforeEach(async () => {
        // get trx signers
		[deployer, alice] = await ethers.getSigners();

        // lead node
        const leafNode = [ethers.utils.solidityKeccak256(["address", "uint256"], [alice.address, parse(usdtAmount.toString(), 6)])].map(leaf => ethers.utils.keccak256(leaf));

        // get merkle poof
        merkleTree = new MerkleTree(leafNode, ethers.utils.keccak256, { sortPairs: true });

        // get merkle root
        root = merkleTree.getRoot();

        // get merkle proof
        proof = merkleTree.getHexProof(leafNode[0]);

        // deloy contracts
		({ para, usdt, presale } = await deployContracts(root));

        // approve usdt
        await usdt.transfer(alice.address, usdtAmount);
        await usdt.connect(alice).approve(presale.address, usdtAmount);
	});

    it ("Alice vest 500 usdt, claim paradox, claim vested paradox after a month", async () => {
        // check canClaim
        expect(await presale.canClaim(alice.address, usdtAmount, proof)).to.equal(true);

        // claim paradox based on the usdt
        await presale.claimParadox(alice.address, usdtAmount, proof);

        // check usdt & paradox amount
        expect(format(await para.balanceOf(alice.address), 18).toFixed(0)).to.equal("200000");
        expect(format(await usdt.balanceOf(presale.address), 6).toFixed(0)).to.equal("500");

        // get pending vesteClaim
        expect(format(await para.pendingVestedClaim(alice.address), 18).toFixed(0)).to.equal("0");

        // fast forward a month
        await network.provider.send("evm_increaseTime", [3600 * 24 * 30]);
        await network.provider.send("evm_mine");

        // check pending vestClaim
        expect(format(await para.pendingVestedClaim(alice.address), 18).toFixed(0)).to.equal("200000");

        // claim vested Para
        await presale.claimVested(alice.address);

        // check claimed Para
        expect(format(await para.balanceOf(alice.address), 18).toFixed(0)).to.equal("400000");
    });
    it("Cannot claim twice", async () => {})
    it("Claims and a new merkle root is added, can no longer claim under any circumstances", async () => {})
    // for this one, just add a hardhat wallet public key to the data and a number amount in the field
    it("Claims and a new merkle root is added, new additions can claim", async () => {})
});