(*******************************************************************************
  Logger4D - a professional logging library for Delphi and Free Pascal

  Author:    Shaahin Ashayeri
  GitHub:    https://github.com/DelphiMan68
  License:   MIT (see the LICENSE file)
  Copyright (c) 2026 Shaahin Ashayeri
*******************************************************************************)

(*******************************************************************************
  Logger4D - compiler configuration

  Included at the very top of every Logger4D unit.
  Supported compilers: Delphi XE2 or newer, Free Pascal 3.2.0 or newer.
*******************************************************************************)

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$MODESWITCH ADVANCEDRECORDS}
{$ELSE}
  {$IF CompilerVersion < 23}
    {$MESSAGE FATAL 'Logger4D requires Delphi XE2 or newer.'}
  {$IFEND}
{$ENDIF}
