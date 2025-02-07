import PdfValue
import PdfDecl
import StandardEncodings
import Debug

--------------------------------------------------------------------------------
-- Section 7.7.2, Table 29
def PdfCatalog (strict : bool) (enc : maybe StdEncodings) (r : Ref) =
  block
    let ?strict = strict
    let ?doText = enc
    let d       = ResolveValRef r is dict
    pageTree = PdfPageTreeRoot (LookupRef "Pages" d)
    stdEncodings = case enc of
                     nothing -> noStdEncodings
                     just e  -> e
    -- other fields omitted


--------------------------------------------------------------------------------
-- Page Tree; Section 7.7.3

def PdfPageTreeRoot (r : Ref) = PdfPageTree nothing noResources r

def PdfPageTree (p : maybe Ref) (parentResources : Resources) (r : Ref) =
  block
    let node = ResolveValRef r is dict
    PdfCheckParent p node

    {- Since resources are shared, we want to process them once at the
    node and pass the processed resources down the tree, otherwise
    we are going to reprocess them again for each leaf which is a lot
    of repeated work in large doucuments. -}
    let resources = case Optional (Lookup "Resources" node) of
                      just v  -> Resources v <| parentResources -- if `GetFonts` fails in `Resources` then assign the parentResources
                      nothing -> parentResources
    let type = LookupResolve "Type" node is name
    if type == "Pages"
       then {| Node = map (child in (LookupResolve "Kids" node is array))
                          (PdfPageTree (just r) resources (child is ref))
            |}

       else if type == "Page"
              then {| Leaf = PdfPage resources node |}
              else Fail "Unexpected `Type` in page tree"

def noResources : Resources =
  block
    fonts = empty

def Resources (v : Value) =
  block
    fonts = GetFonts (ResolveVal v is dict)
    -- others resources omitted
    -- we need the fonts because they determine the character encoding to use

def PdfCheckParent (p : maybe Ref) (d : Dict) =
  (case Optional (Lookup "Parent" d) of
    nothing -> p is nothing
    just v  -> p == just (v is ref) is true
  )
   <| Fail "Malformed node parent"

--------------------------------------------------------------------------------



--------------------------------------------------------------------------------
-- Page. Section 7.7.3.3, Table 31

def PdfPage (resources : Resources) (pageNode : Dict) =
  case Optional (Lookup "Contents" pageNode) of
    nothing -> {| EmptyPage = Accept |}
    just vr -> {| ContentStreams = PdfPageContent resources vr |}

def PdfPageContent (resources : Resources) (vr : Value) =
  block
    resources = resources

    SetStream
      case vr of
        ref r ->
          case ResolveDeclRef r of
            value v  -> StreamFromArray (v is array)
            stream s -> ( s.body is ok
                         <|
                          { @x = s.body is undecoded
                          ; Trace "WARNING: undecoded stream"
                          ; ^ x }
                        )

        array xs -> StreamFromArray xs

    data = block
             ManyWS
             Many ContentStreamEntry

    UNPARSED = if ?strict then { END; [] } else Many UInt8


        -- inefficient!
def StreamFromArray (xs : [Value]) =
  block
    let chunks = map (x in xs)
                    block
                    let bs = bytesOfStream (ContentStreamBytes (x is ref))
                    concat [bs, " "] -- yikes.

    arrayStream (concat chunks)



def ContentStreamBytes (r : Ref) : stream = block
  let bdy = (ResolveStreamRef r).body
  ( bdy is ok
    <|
      { @x = bdy is undecoded
      ; Trace "WARNING: undecoded ContentStreamBytes"
      ; ^ x
      }
    )


--------------------------------------------------------------------------------
-- Content Steram instrutctions

def ContentStreamEntry =
  First
    value    = Value
    operator = ContentStreamOperator

def ContentStreamOperator =
  Token
  First
    -- note that the lengths here are important!

    -- 3
    BDC     = @Match "BDC"
    BMC     = @Match "BMC"
    SCN     = @Match "SCN"
    scn     = @Match "scn"
    EMC     = @Match "EMC"

    -- 2
    b_star  = @Match "b*"
    B_Star  = @Match "B*"

    BT      = @Match "BT"
    ET      = @Match "ET"


    BX      = @Match "BX"
    cm      = @Match "cm"
    CS      = @Match "CS"
    d0      = @Match "d0"
    d1      = @Match "d1"
    Do      = @Match "Do"
    DP      = @Match "DP"
    EX      = @Match "EX"
    f_star  = @Match "f*"
    gs      = @Match "gs"

    BI      = @Match "BI"
    ID      = block
                $$ = Match "ID"
                SkipImageData -- This consumes EI

    MP      = @Match "MP"
    re      = @Match "re"
    RG      = @Match "RG"
    rg      = @Match "rg"
    ri      = @Match "ri"
    SC      = @Match "SC"
    sc      = @Match "sc"
    sh      = @Match "sh"
    T_star  = @Match "T*"
    Tc      = @Match "Tc"
    Td      = @Match "Td"
    TD      = @Match "TD"
    Tf      = @Match "Tf"
    Tj      = @Match "Tj"
    TJ      = @Match "TJ"
    TL      = @Match "TL"
    Tm      = @Match "Tm"
    Tr      = @Match "Tr"
    Ts      = @Match "Ts"
    Tw      = @Match "Tw"
    Tz      = @Match "Tz"
    W_star  = @Match "W*"

    -- 1
    b       = @Match "b"
    B       = @Match "B"
    c       = @Match "c"
    d       = @Match "d"
    f       = @Match "f"
    F       = @Match "F"
    G       = @Match "G"
    g       = @Match "g"
    h       = @Match "h"
    i       = @Match "i"
    j       = @Match "j"
    J       = @Match "J"
    K       = @Match "K"
    k       = @Match "k"
    l       = @Match "l"
    m       = @Match "m"
    M       = @Match "M"
    n       = @Match "n"
    q       = @Match "q"
    Q       = @Match "Q"
    s       = @Match "s"
    S       = @Match "S"
    v       = @Match "v"
    w       = @Match "w"
    W       = @Match "W"
    y       = @Match "y"
    quote   = @Match "'"
    dquote  = @Match "\""

-- Skip image data
def SkipImageData =
  block
    Many $[!'E']
    $['E']
    @$['I'] <| SkipImageData

--------------------------------------------------------------------------------

-- XXX: It'd be nice to cache preocessed fonts by reference so if we encounter
-- the same reference we don't parse it over and over again.
-- (this might be a generally useful thing to have)
def GetFonts (r : Dict) : [ [uint 8] -> Font ] =
  case ?doText of
    nothing -> empty
    just enc ->
      block
        let ?stdEncodings = enc
        case Optional (Lookup "Font" r) of
          nothing -> empty
          just v  ->
            map (v in (ResolveVal v is dict)) (Font v)

def Font (v : Value) =
  block
    let dict = ResolveVal v is dict
    subType   = ResolveVal (Lookup "Subtype" dict) is name
    encoding  = GetEncoding dict
    toUnicode = case Optional (Lookup "ToUnicode" dict) of
                  nothing -> nothing
                  just v  -> just (ToUnicodeCMap v)

def namedEncoding (encName : [uint 8]) =
  if encName == "WinAnsiEncoding"  then just ?stdEncodings.win else
  if encName == "MacRomanEncoding" then just ?stdEncodings.mac else
  if encName == "PDFDocEncoding"   then just ?stdEncodings.pdf else
  if encName == "StandardEncoding" then just ?stdEncodings.std else
  nothing


def GetEncoding (d : Dict) : maybe [uint 8 -> [uint 16]] =
  case lookup "Encoding" d of
    nothing -> nothing
    just v ->
     block
      case ResolveVal v of
        name encName -> namedEncoding encName
        dict encD ->
          block
            let base = case lookup "BaseEncoding" encD of
                         just ev -> namedEncoding (ResolveVal ev is name)
                         nothing -> nothing
            case lookup "Differences" encD of
              nothing -> base
              just d  -> just (EncodingDifferences base (ResolveVal d is array))

        _ -> nothing


def EncodingDifferences base ds : [ uint 8 -> [uint 16] ]=
  block
    let start = case base of
                  nothing -> ?stdEncodings.std
                  just e  -> e
    let s = for (s = { enc = start, code = 0 }; x in ds)
             case ResolveVal x of
               number n -> { enc = s.enc, code = NumberAsNat n as? uint 8 }
               name x ->
                 { enc  = case lookup x ?stdEncodings.uni of
                            just u  -> insert s.code u s.enc
                            nothing ->
                              block
                                -- Trace (concat ["Missing: ", x])
                                insert s.code
                                  (map (c in concat ["[",x,"]"])
                                       (c as uint 16)) s.enc
                 , code = s.code + 1
                 }

    s.enc



--------------------------------------------------------------------------------
-- Character Maps

def ToUnicodeCMap (v : Value) =
  case v of
    ref r ->
      case ResolveDeclRef r of
        value v  -> {| named = v is name |}
        stream s -> {| cmap = ToUnicodeCMapDef s |}
    name x -> {| named = x |}

-- XXX: .. in patterns
def HexNum acc =
  block
    let b = UInt8
    case b of
      '0', '1','2','3','4','5','6','7','8','9' ->
        HexNum (16 * acc + ((b - '0') as ?auto))

      'a', 'b', 'c', 'd', 'e', 'f' ->
        HexNum (16 * acc + (10 + (b - 'a') as ?auto))

      'A', 'B', 'C', 'D', 'E', 'F' ->
        HexNum (16 * acc + (10 + (b - 'A') as ?auto))

      '>' -> acc

def HexD =
  First
    $['0' .. '9'] - '0'
    10 + $['a' .. 'f'] - 'a'
    10 + $['A' .. 'F'] - 'A'

def HexByte = 16 * HexD + HexD

def Hex : uint 32 = block $['<']; HexNum 0

def HexBytes (lo : uint 64) (hi : uint 64) =
  block
    Token $['<']
    $$ = Many (1 .. 4) HexByte
    Token $['>']


def ToUnicodeCMapDef (s : Stream) =
  block
    SetStream (s.body is ok)
    -- Trace (bytesOfStream (s.body is ok))
    ManyWS
    Name == "CIDInit" is true
    Name == "ProcSet" is true
    KW "findresource"
    KW "begin"
    -- XXX: don't quite understand the dict/dup format thing
    let size = Token Natural
    KW "dict"
    -- XXX: don't quite understand the dict/dup format thing
    KW "begin"
    KW "begincmap"
    $$ = CMapEntries cmap
    KW "endcmap"
    -- XXX: ignore rest


def cmap =
  block
    charMap = empty : [ uint 32 -> uint 32 ]
    ranges  = []    : [ CodespaceRangeEntry ]

def insertChar x y (acc : cmap) : cmap =
  block
    charMap = insert x y acc.charMap
    ranges  = acc.ranges

def addCodespaceRange xs (acc : cmap) : cmap =
  block
    charMap = acc.charMap
    ranges  = concat [ xs, acc.ranges ] -- yikes


def CMapEntries acc =
  case Optional CMapKeyVal of
    nothing ->
      case Optional (CMapOperator acc) of
        just acc1 -> CMapEntries acc1
        nothing   -> acc

    just _  -> CMapEntries acc   -- ignore metadata

def CMapKeyVal =
  block
    key   = Name
    value = CMapValue
    Optional (KW "def")

def CMapValue =
  First
    dict    = CMapDict
    string  = String
    string  = HexString
    name    = Name
    number  = Number

def CMapDict =
  block
    let ents = Between "<<" ">>" (Many CMapKeyVal)
    for (d = empty; e in ents) (insert e.key e.value d)

def CMapOperator (acc : cmap) =
  block
    let size = Token Natural as? uint 64
    size <= 100 is true
    Match "begin"
    let op = Token (Many $['a' .. 'z'])
    $$ =      if op == "bfrange" then BFRangeMapping acc size
         else if op == "bfchar"  then BFCharMapping acc size
         else if op == "codespacerange" then
                  addCodespaceRange (Many size CodespaceRangeEntry) acc
         else Fail "Unsupported operator"
    Match "end"
    Token (Match op)

def CodespaceRangeEntry =
  block
    start = HexBytes 1 4
    end   = HexBytes 1 4

-- 00 00 -- FF FF

-- start    end
-- 00       50
-- 40 00    60 10

def BFCharMapping acc count =
  if count > 0 then
    block
      let key = Token Hex
      let val = Token Hex
      BFCharMapping (insertChar key val acc) (count - 1)
  else
    acc

def BFRangeMapping acc count =
  if count > 0 then
    block
      let start = Token Hex
      let end   = Token Hex
      let tgt   = Token Hex
      if end < start
        then BFRangeMapping acc (count - 1)
        else block
               let ?start  = start
               let ?target = tgt
               let ?count  = end - start + 1
               BFRangeMapping (insertRange 0 acc) (count - 1)
  else
    acc

def insertRange (i : uint 32) (acc : cmap) =
  if i < ?count
    then insertRange (i+1) (insertChar (?start + i) (?target + i) acc)
    else acc


--------------------------------------------------------------------------------
-- Hacky "validation" we look for JavaScript or URI actions

-- Return `true` if this declaration is "safe"
def CheckRef (r : Ref) : bool =
  case ResolveDeclRef r of
    stream  -> true
    value v ->
      First
        block
          FindUnsafe v
          false
        true


def FindUnsafe (v : Value) =
  case v of
    dict d ->
      First
        block
          let act = ResolveVal (Lookup "S" d) is name
          (act == "JavaScript" || act == "URI") is true
        @Lookup "JS" d

    array xs ->
      block
        let ?vals = xs
        AnyUnsafe 0

    _        -> Fail "not unsafe"


def AnyUnsafe i =
  block
    let v = Index ?vals i
    FindUnsafe v <| AnyUnsafe (i+1)

