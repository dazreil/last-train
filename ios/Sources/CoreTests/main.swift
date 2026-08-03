import Foundation

/**
 The native app's test suite.

 Run:  cd ios && TZ=UTC swift run CoreTests

 `TZ=UTC` is deliberate and matches `npm test`. The bug these tests exist to prevent
 is invisible on a machine set to London, because there the wrong answer and the right
 one are the same answer.
 */

let runner = TestRunner()

serviceDayTests(runner)

exit(runner.finish())
