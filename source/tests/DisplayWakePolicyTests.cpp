// SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
#include "platform/DisplayWakePolicy.h"
#include <cstdlib>
#include <iostream>
static void check(bool result, const char *message) {
  if (!result) { std::cerr << message << '\n'; std::exit(1); }
}
int main() {
  DisplayWakePolicy policy;
  check(!policy.requestFromInput(true, false), "unknown state must never wake");
  policy.displayState(0);
  for (int i = 0; i != 100; ++i)
    check(!policy.requestFromInput(false, false), "default-off policy requested wake");
  check(!policy.requestFromInput(true, true), "primary computer requested remote wake");
  check(policy.requestFromInput(true, false), "first opted-in remote input did not request wake");
  for (int i = 0; i != 100; ++i) {
    policy.displayState(0);
    check(!policy.requestFromInput(true, false), "repeated input/off notification rearmed wake");
  }
  policy.displayState(1);
  check(!policy.requestFromInput(true, false), "lit screen requested wake");
  policy.displayState(2);
  check(!policy.requestFromInput(true, false), "dim screen requested wake");
  policy.displayState(0);
  check(policy.requestFromInput(true, false), "new off cycle was not rearmed");
  std::cout << "Display wake checks passed: unknown/default-off/primary never request; actual opted-in input once per off cycle.\n";
}
