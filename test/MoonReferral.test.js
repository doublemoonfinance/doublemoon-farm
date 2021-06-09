const { expectRevert } = require('@openzeppelin/test-helpers');
const { assert } = require('chai');

const MoonReferral = artifacts.require('MoonReferral');

contract('MoonReferral', ([alice, bob, carol, referrer, operator, owner]) => {
    beforeEach(async () => {
        this.MoonReferral = await MoonReferral.new({ from: owner });
        this.zeroAddress = '0x0000000000000000000000000000000000000000';
    });

    it('should allow operator and only owner to update operator', async () => {
        assert.equal((await this.MoonReferral.operators(operator)).valueOf(), false);
        await expectRevert(this.MoonReferral.recordReferral(alice, referrer, { from: operator }), 'Operator: caller is not the operator');

        await expectRevert(this.MoonReferral.updateOperator(operator, true, { from: carol }), 'Ownable: caller is not the owner');
        await this.MoonReferral.updateOperator(operator, true, { from: owner });
        assert.equal((await this.MoonReferral.operators(operator)).valueOf(), true);

        await this.MoonReferral.updateOperator(operator, false, { from: owner });
        assert.equal((await this.MoonReferral.operators(operator)).valueOf(), false);
        await expectRevert(this.MoonReferral.recordReferral(alice, referrer, { from: operator }), 'Operator: caller is not the operator');
    });

    it('record referral', async () => {
        assert.equal((await this.MoonReferral.operators(operator)).valueOf(), false);
        await this.MoonReferral.updateOperator(operator, true, { from: owner });
        assert.equal((await this.MoonReferral.operators(operator)).valueOf(), true);

        await this.MoonReferral.recordReferral(this.zeroAddress, referrer, { from: operator });
        await this.MoonReferral.recordReferral(alice, this.zeroAddress, { from: operator });
        await this.MoonReferral.recordReferral(this.zeroAddress, this.zeroAddress, { from: operator });
        await this.MoonReferral.recordReferral(alice, alice, { from: operator });
        assert.equal((await this.MoonReferral.getReferrer(alice)).valueOf(), this.zeroAddress);
        assert.equal((await this.MoonReferral.referralsCount(referrer)).valueOf(), '0');

        await this.MoonReferral.recordReferral(alice, referrer, { from: operator });
        assert.equal((await this.MoonReferral.getReferrer(alice)).valueOf(), referrer);
        assert.equal((await this.MoonReferral.referralsCount(referrer)).valueOf(), '1');

        assert.equal((await this.MoonReferral.referralsCount(bob)).valueOf(), '0');
        await this.MoonReferral.recordReferral(alice, bob, { from: operator });
        assert.equal((await this.MoonReferral.referralsCount(bob)).valueOf(), '0');
        assert.equal((await this.MoonReferral.getReferrer(alice)).valueOf(), referrer);

        await this.MoonReferral.recordReferral(carol, referrer, { from: operator });
        assert.equal((await this.MoonReferral.getReferrer(carol)).valueOf(), referrer);
        assert.equal((await this.MoonReferral.referralsCount(referrer)).valueOf(), '2');
    });

    it('record referral commission', async () => {
        assert.equal((await this.MoonReferral.totalReferralCommissions(referrer)).valueOf(), '0');

        await expectRevert(this.MoonReferral.recordReferralCommission(referrer, 1, { from: operator }), 'Operator: caller is not the operator');
        await this.MoonReferral.updateOperator(operator, true, { from: owner });
        assert.equal((await this.MoonReferral.operators(operator)).valueOf(), true);

        await this.MoonReferral.recordReferralCommission(referrer, 1, { from: operator });
        assert.equal((await this.MoonReferral.totalReferralCommissions(referrer)).valueOf(), '1');

        await this.MoonReferral.recordReferralCommission(referrer, 0, { from: operator });
        assert.equal((await this.MoonReferral.totalReferralCommissions(referrer)).valueOf(), '1');

        await this.MoonReferral.recordReferralCommission(referrer, 111, { from: operator });
        assert.equal((await this.MoonReferral.totalReferralCommissions(referrer)).valueOf(), '112');

        await this.MoonReferral.recordReferralCommission(this.zeroAddress, 100, { from: operator });
        assert.equal((await this.MoonReferral.totalReferralCommissions(this.zeroAddress)).valueOf(), '0');
    });
});
