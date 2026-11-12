@echo off
rem Builds all examples with Free Pascal 3.2+ (Windows).
if not exist bin mkdir bin
for %%p in (BasicExample AdvancedExample ExtraAppendersExample) do fpc -Fu..\..\Source -FUbin -FEbin %%p.lpr
