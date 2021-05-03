const { assert } = require("chai");

const DoubleMoonCash = artifacts.require('DoubleMoonCash');

contract('DoubleMoonCash', ([alice, bob, carol, dev, minter]) => {
    beforeEach(async () => {
        this.cake = await DoubleMoonCash.new({ from: minter });
    });


    it('mint', async () => {
        await this.cake.mint(alice, 1000, { from: minter });
        assert.equal((await this.cake.balanceOf(alice)).toString(), '1000');
    })
});
