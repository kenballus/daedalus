import nitf_lib

def DE = Match "DE"

def DataExtHeader = block
  DE
  desid = Many 25 BCSA
  desver = PosNumber 2

  common = CommonSubheader

  -- NOTE-MODERN: looks like the outer `Choose` should be `Choose1`,
  -- should double-check that the second branch does not make progress
  desoflw = First
              present = First
                          oflwUDHD  = @(PadMatch 6 ' ' "UDHD")
                          oflwUDID  = @(PadMatch 6 ' ' "UDID")
                          oflwXHD   = @(PadMatch 6 ' ' "XHD")
                          oflwIXSHD = @(PadMatch 6 ' ' "IXSHD")
                          oflwSXSHD = @(PadMatch 6 ' ' "SXSHD")
                          oflwTXSHD = @(PadMatch 6 ' ' "TXSHD")
              nooflw = Accept

  dsitem = First
             present = { desoflw is present; UnsignedNum 3 }
             omitted = desoflw is nooflw

  desshl = IsNum 4 0
