import assert from "assert";
import { 
  TestHelpers,
  HotPotato_Claim
} from "generated";
const { MockDb, HotPotato } = TestHelpers;

describe("HotPotato contract Claim event tests", () => {
  // Create mock db
  const mockDb = MockDb.createMockDb();

  // Creating mock for HotPotato contract Claim event
  const event = HotPotato.Claim.createMockEvent({/* It mocks event fields with default values. You can overwrite them if you need */});

  it("HotPotato_Claim is created correctly", async () => {
    // Processing the event
    const mockDbUpdated = await HotPotato.Claim.processEvent({
      event,
      mockDb,
    });

    // Getting the actual entity from the mock database
    let actualHotPotatoClaim = mockDbUpdated.entities.HotPotato_Claim.get(
      `${event.chainId}_${event.block.number}_${event.logIndex}`
    );

    // Creating the expected entity
    const expectedHotPotatoClaim: HotPotato_Claim = {
      id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
      player: event.params.player,
      roundId: event.params.roundId,
      amount: event.params.amount,
    };
    // Asserting that the entity in the mock database is the same as the expected entity
    assert.deepEqual(actualHotPotatoClaim, expectedHotPotatoClaim, "Actual HotPotatoClaim should be the same as the expectedHotPotatoClaim");
  });
});
