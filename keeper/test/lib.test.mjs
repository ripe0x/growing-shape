import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dueJobs, decayDue, expectedReward, ACQ } from '../lib.mjs';

const base = () => ({
  storedUndelivered: [],
  head: null,
  block: 100n,
  processed: 10n,
  booked: 10n,
  ownerProceeds: 0n,
  bookBatch: 50n,
  unsettled: 0n,
  retired: false,
  replacementDue: 0n,
  operating: 1n * 10n ** 18n,
  cheapestTierCost: 11n * 10n ** 15n,
  seedCost: 501n * 10n ** 15n,
  compositionDue: false,
  repriceStepBps: 500,
  featured: { listingId: 7n, desired: 500n, notional: 500n, floor: 50n },
});

test('idle game needs nothing', () => assert.deepEqual(dueJobs(base()), []));

test('unbooked draws, proceeds or a processable head trigger book', () => {
  assert.deepEqual(dueJobs({ ...base(), processed: 12n }).map((j) => j.name), ['book']);
  assert.deepEqual(dueJobs({ ...base(), ownerProceeds: 1n }).map((j) => j.name), ['book']);
  const expired = { ...base(), head: { status: ACQ.Pending, deadline: 90n } };
  assert.deepEqual(dueJobs(expired).map((j) => j.name), ['book']);
  const waiting = { ...base(), head: { status: ACQ.Pending, deadline: 120n }, unsettled: 1n };
  assert.deepEqual(dueJobs(waiting), []);
});

test('compose and decay wait for an idle, fully booked pool', () => {
  const due = { ...base(), compositionDue: true, featured: { listingId: 7n, desired: 470n, notional: 500n, floor: 50n } };
  assert.deepEqual(dueJobs(due).map((j) => j.name), ['compose', 'publishDecay']);
  assert.deepEqual(dueJobs({ ...due, unsettled: 1n }), []);
  assert.deepEqual(dueJobs({ ...due, processed: 11n }).map((j) => j.name), ['book']);
});

test('decay publishes at one step or at the floor', () => {
  const f = (desired, notional, floor = 50n) => decayDue({ repriceStepBps: 500, featured: { desired, notional, floor } });
  assert.equal(f(476n, 500n), false);
  assert.equal(f(475n, 500n), true);
  assert.equal(f(50n, 52n), true);
  assert.equal(f(50n, 50n), false);
});

test('restart and replenish need operating ETH', () => {
  const won = { ...base(), featured: { listingId: 0n, desired: 0n, notional: 0n, floor: 0n }, replacementDue: 11n * 10n ** 15n };
  assert.deepEqual(dueJobs(won).map((j) => j.name), ['replenish', 'startCycle']);
  assert.deepEqual(dueJobs({ ...won, operating: 10n ** 15n }), []);
  assert.deepEqual(dueJobs({ ...won, retired: true }), []);
});

test('reward caps price at basefee + priority and at budget', () => {
  const keeper = { priorityCap: 10n ** 9n, gasPriceCap: 20n * 10n ** 9n, gasOverhead: 30_000n, flatReward: 2n * 10n ** 14n, flatInterval: 600n };
  const args = { gas: 270_000n, gasPrice: 50n * 10n ** 9n, baseFee: 3n * 10n ** 9n, now: 1000n, keeper, keeperBudget: 10n ** 18n, operating: 10n ** 18n, lastFlatRewardAt: 0n };
  assert.equal(expectedReward(args), 300_000n * 4n * 10n ** 9n + 2n * 10n ** 14n);
  assert.equal(expectedReward({ ...args, lastFlatRewardAt: 900n }), 300_000n * 4n * 10n ** 9n);
  assert.equal(expectedReward({ ...args, keeperBudget: 5n }), 5n);
});
