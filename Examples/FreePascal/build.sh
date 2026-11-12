#!/bin/sh
# Builds all examples with Free Pascal 3.2+ (Linux / macOS).
mkdir -p bin
for p in BasicExample AdvancedExample ExtraAppendersExample; do
  fpc -Fu../../Source -FUbin -FEbin $p.lpr
done
