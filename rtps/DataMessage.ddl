-- Definition of DDS messages, based on the DDSI-RTPS spec.
import Stdlib

-- TODO: account for endianness encoding modes
def Octet = UInt8

def OctetArray2 = Many 2 Octet

def OctetArray3 = Many 3 Octet

-- Big Endian parsers:
def EndUShort littleEnd = End16 littleEnd
def EndULong littleEnd = End32 littleEnd
def EndLong littleEnd = EndSign32 littleEnd

-- Sec. 8.3.3 The Overall strucutre of an RTPS Message: the overall
-- structure of an RTPS Message consists of a fixed-size leading RTPS
-- Header followed by a variable number of RTPS Submessage
-- parts. Fig. 8.8:
-- DBG:
def Message PayloadData = {
-- def Message = {
  header = Header;
-- DBG:
  submessages = Many (Submessage PayloadData);
--  subm0 = Submessage PayloadData;
--  subm0 = Submessage;
  END
}

-- Sec. 8.3.3.1 Header Structure. Table 8.14:
def Header = {
  protocol = Protocol;
  version = ProtocolVersion;
  vendorId = VendorId;
  guidPrefix = GuidPrefix;
}

-- Sec. 8.3.3.1.1 protocol: value is set to PROTOCOL_RTPS
def Protocol = ProtocolRTPS

-- Sec. 8.3.3.1.2 version:
def ProtocolVersion = {
  major = Octet;
  mintor = Octet;
}

def VendorId = Many 2 Octet

def ProtocolRTPS = Match "RTPS" 

def GuidPrefix = Many 12 Octet

-- DBG:
def Submessage PayloadData = {
  subHeader = SubmessageHeader;
  elt = Choose1 {
    { Guard (subHeader.submessageLength > 0);
      Chunk
        (subHeader.submessageLength as uint 64)
        (SubmessageElement PayloadData subHeader.flags);
    };
    { Guard (subHeader.submessageLength == 0);
      $$ = SubmessageElement PayloadData subHeader.flags;
      Many Octet; -- TODO: this is maybe too sloppy
    };
  }
}

-- Sec 8.3.3.2 Submessage structure: Table 8.15:
def SubmessageHeader = {
  submessageId = SubmessageId;
  flags = SubmessageFlags submessageId;
  submessageLength = EndUShort flags.endiannessFlag;
}

-- Sec 8.3.3.2.1 SubmessageId: a SubmessageKind (Sec 9.4.5.1.1)
def SubmessageId = Choose1{
  pad = @Match1 0x01;
  acknack = @Match1 0x06;
  heartbeat = @Match1 0x07;
  gap = @Match1 0x08;
  infoTs = @Match1 0x09;
  infoSrc = @Match1 0x0c;
  infoReplyIP4 = @Match1 0x0d;
  infoDst = @Match1 0x0e;
  infoReply = @Match1 0x0f;
  nackFrag = @Match1 0x12;
  heartbeatFrag = @Match1 0x13;
  data = @Match1 0x15;
  dataFrag = @Match1 0x16;
}

def NthBit n fs = {
  ^((fs .&. (1 << n)) != 0);
}

-- SubmessageFlags:

def SubmessageFlags (subId: SubmessageId) = { 
  @flagBits = UInt8;
  endiannessFlag = NthBit 0 flagBits;
  subFlags = Choose1 {
    ackNackFlags = {
      subId is acknack;
      finalFlag = NthBit 1 flagBits;
    };
    dataFlags = {
      subId is data;
      inlineQosFlag = NthBit 1 flagBits;
      dataFlag = NthBit 2 flagBits;
      keyFlag = NthBit 3 flagBits;
      Guard (!(dataFlag && keyFlag)); -- invalid combo

      nonStandardPayloadFlag = NthBit 4 flagBits;
    };
    dataFragFlags = {
      subId is dataFrag;
      inlineQosFlag = NthBit 1 flagBits;
      keyFlag = NthBit 2 flagBits;
      nonStandardPayloadFlag = NthBit 3 flagBits;
    };
    gapFlags = {
      subId is gap;
      groupInfoFlag = NthBit 1 flagBits;
    };
    heartBeatFlags = {
      subId is heartbeat;
      finalFlag = NthBit 1 flagBits;
      livelinessFlag = NthBit 2 flagBits;
      groupInfoFlag = NthBit 3 flagBits;
    };
    heartBeatFragFlags = {
      subId is heartbeatFrag;
    };
    infoDstFlags = {
      subId is infoDst;
    };
    infoReplyFlags = {
      subId is infoReply;
      multicastFlag = NthBit 1 flagBits;
    };
    infoSourceFlags = {
      subId is infoSrc;
    };
    infoTimestampFlags = {
      subId is infoTs;
      invalidateFlag = NthBit 1 flagBits;
    };
    padFlags = {
      subId is pad;
    };
    nackFragFlags = {
      subId is acknack;
    };
    infoReplyIP4Flags = {
      subId is infoReplyIP4;
      multicastFlag = NthBit 1 flagBits;
    };
  }
}

def QosParams littleEnd f = Choose1 {
  { Guard f;
    ParameterList littleEnd;
  };
  { Guard (!f);
    ^[]
  }
}

def SubmessageElement PayloadData (flags: SubmessageFlags) = Choose1 {
  ackNackElt = {
    @ackNackFlags = flags.subFlags is ackNackFlags;
    readerId = EntityId;
    writerId = EntityId;
    readerSNState = SequenceNumberSet flags.endiannessFlag;
    count = Count flags.endiannessFlag;
  };
  dataElt = {
    @dFlags = flags.subFlags is dataFlags;
    Match [0x00, 0x00]; -- extra flags for future compatibility
    octetsToInlineQos = EndUShort flags.endiannessFlag; 

    rdWrs = Chunk (octetsToInlineQos as uint 64)
    {
      readerId = EntityId;
      writerId = EntityId;
      writerSN = SequenceNumber flags.endiannessFlag;
      Guard (writerSN > 0);
    };

    inlineQos = QosParams flags.endiannessFlag dFlags.inlineQosFlag;
    serializedPayload = Choose1 {
      hasData = {
        Guard dFlags.dataFlag;
        SerializedPayload PayloadData inlineQos;
      };
      hasKey = Guard dFlags.keyFlag;
      noPayload = Guard (!(dFlags.dataFlag || dFlags.keyFlag));
    };
  };
  dataFragElt = {
    @fragFlags = flags.subFlags is dataFragFlags;
    Match [0x00, 0x00]; -- extraFlags
    octetsToInlineQos = EndUShort flags.endiannessFlag;

    Chunk (octetsToInlineQos as uint 64) {
    };

    readerId = EntityId;
    writerId = EntityId;

    writerSN = SequenceNumber flags.endiannessFlag;
    Guard (writerSN > 0);

    fragmentStartingNum = FragmentNumber flags.endiannessFlag;
    Guard (0 < fragmentStartingNum);
    
    fragmentsInSubmessage = EndUShort flags.endiannessFlag;
    Guard (fragmentStartingNum <= (fragmentsInSubmessage as uint 32));

    fragmentSize = EndUShort flags.endiannessFlag;
    Guard (fragmentSize <= 64000);

    sampleSize = EndULong flags.endiannessFlag;
    Guard (fragmentSize as uint 32 < sampleSize); 

    inlineQos = QosParams flags.endiannessFlag fragFlags.inlineQosFlag;

    serializedPayload = Choose1 {
      hasData = {
        Guard (!(fragFlags.keyFlag));
        Chunk
          ((fragmentsInSubmessage * fragmentSize) as uint 64)
          (Many
            ((fragmentsInSubmessage as uint 32 -
              fragmentStartingNum) as uint 64)
            (SerializedPayload PayloadData inlineQos));
      };
      hasKey = Guard fragFlags.keyFlag;
    };
  };
  gapElt = {
    @gapFlags0 = flags.subFlags is gapFlags;
    readerId = EntityId;
    writerId = EntityId;

    gapStart = SequenceNumber flags.endiannessFlag;
    Guard (gapStart > 0);

    gapList = SequenceNumberSet flags.endiannessFlag;

    -- WARNING: layout of these is not defined at PSM level. This is a
    -- guess.
    Choose1 {
      hasGpInfo = {
        Guard (gapFlags0.groupInfoFlag);

        gapStartGSN = SequenceNumber flags.endiannessFlag;
        Guard (gapStartGSN > 0);

        gapEndGSN = SequenceNumber flags.endiannessFlag;
        Guard (gapEndGSN >= gapStartGSN - 1);
      };
      noGpInfo = Guard (!(gapFlags0.groupInfoFlag));
    }
  };
  heartBeatElt = {
    @hbFlags = flags.subFlags is heartBeatFlags;
    readerId = EntityId;
    writerId = EntityId;

    firstSN = SequenceNumber flags.endiannessFlag;
    Guard (firstSN > 0);

    lastSN = SequenceNumber flags.endiannessFlag;
    Guard (lastSN >= firstSN - 1);
    count = Count flags.endiannessFlag;

    -- WARNING: layout of these is not defined at PSM level. This is a
    -- guess, based on Table 8.38.
    Choose1 {
      hasGpInfo = {
        Guard (hbFlags.groupInfoFlag);

        currentGSN = SequenceNumber flags.endiannessFlag;

        firstGSN = SequenceNumber flags.endiannessFlag;
        Guard (firstGSN > 0);
        Guard (currentGSN >= firstGSN);

        lastGSN = SequenceNumber flags.endiannessFlag;
        Guard (lastGSN >= firstGSN - 1);
        Guard (currentGSN >= lastGSN);

        writerSet = GroupDigest;
        secureWriterSet = GroupDigest;
      };
      noGpInfo = Guard (!(hbFlags.groupInfoFlag));
    }
  };
  heartBeatFragElt = {
    @hbFragFlags = flags.subFlags is heartBeatFragFlags;
    readerId = EntityId;
    writerId = EntityId;

    writerSN = SequenceNumber flags.endiannessFlag;
    Guard (writerSN > 0);
    
    lastFragmentNum = FragmentNumber flags.endiannessFlag;
    Guard (lastFragmentNum > 0);

    GuidPrefix;
  };
  timestampElt = {
    @tsFlags0 = flags.subFlags is infoTimestampFlags;
    Choose1 {
      hasTs = {
        Guard (!(tsFlags0.invalidateFlag));
        Time flags.endiannessFlag;
      };
      noTs = Guard (tsFlags0.invalidateFlag);
    }
  };
  padElt = {
    @padFlags = flags.subFlags is padFlags;
  };
  nackFragElt = {
    @nackFlags = flags.subFlags is nackFragFlags;
    readerId = EntityId;
    writerId = EntityId;
    writerSN = SequenceNumber flags.endiannessFlag;
    fragmentNumberState = FragmentNumberSet flags.endiannessFlag;
    count = Count flags.endiannessFlag;
  };
  infoReplyIP4Elt = {
    @replyIP4Flags0 = flags.subFlags is infoReplyIP4Flags;
    unicastLocator = LocatorUDPv4 flags.endiannessFlag;
    multicastLocator = LocatorUDPv4 flags.endiannessFlag;
  }
}

def EntityId = {
  entityKey = OctetArray3;
  entityKind = Octet;
}

def HighBit32 = (1 : uint 32) << 31

-- Sec 9.3.2 Mapping of the Types that Appear Within Submessages...
def SequenceNumber littleEnd = {
  @high = EndULong littleEnd;
  @low = EndULong littleEnd;
  (high .&. ~HighBit32) # low -
  (high .&. HighBit32 as uint 64) << 56 as int
}

def SequenceNumberSet littleEnd = {
  bitmapBase = SequenceNumber littleEnd;
  Guard (bitmapBase >= 1);
  
  numBits = EndULong littleEnd;
  Many ((numBits + 31)/32 as uint 64) (EndLong littleEnd);
}

def GroupDigest = Many 4 Octet

-- Sec 9.4.2.11 ParameterList:

-- Sec 9.6.2.2.2 ParameterID values: Table 9.13:
def ParameterIdT littleEnd = {
  @p = EndUShort littleEnd;
  Choose1 {
    pidPad = Guard (p == 0x0000);
    pidSentinel = Guard (p == 0x0001);
    pidUserData = Guard (p == 0x002c);
    pidTopicName = Guard (p == 0x0005);
    pidTypeName = Guard (p == 0x0007);
    pidGroupData = Guard (p == 0x002d);
    pidTopicData = Guard (p == 0x002e);
    pidDurability = Guard (p == 0x001d);
    pidDurabilityService = Guard (p == 0x001e);
    pidDeadline = Guard (p == 0x0023);
    pidLatencyBudget = Guard (p == 0x0027);
    pidLiveliness = Guard (p == 0x001b);
    pidReliability = Guard (p == 0x001a);
    pidLifespan = Guard (p == 0x002b);
    pidDestinationOrder = Guard (p == 0x0025);
    pidHistory = Guard (p == 0x0040);
    pidResourceLimits = Guard (p == 0x0041);
    pidOwnership = Guard (p == 0x001f);
    pidOwnershipStrength = Guard (p == 0x0006);
    pidPresentation = Guard (p == 0x0021);
    pidPartition = Guard (p == 0x0029);
    pidTimeBasedFilter = Guard (p == 0x0004);
    pidTransportPriority = Guard (p == 0x0049);
    pidDomainId = Guard (p == 0x000f);
    pidDomainTag = Guard (p == 0x4014);
    pidProtocolVersion = Guard (p == 0x0015);
    pidVendorId = Guard (p == 0x0016);
    pidUnicastLocator = Guard (p == 0x002f);
    pidMulticastLocator = Guard (p == 0x0030);
    pidDefaultUnicastLocator = Guard (p == 0x0031);
    pidDefaultMulticastLocator = Guard (p == 0x0048);
    pidMetatrafficUnicastLocator = Guard (p == 0x0032);
    pidMetatrafficMulticastLocator = Guard (p == 0x0033);
    pidExpectsInlineQos = Guard (p == 0x0043);
    pidParticipantManualLivelinessCount = Guard (p == 0x0034);
    pidParticipantLeaseDuration = Guard (p == 0x0002);
    pidContentFilterProperty = Guard (p == 0x0035);
    pidParticipantGuid = Guard (p == 0x0050);
    pidGroupGuid = Guard (p == 0x0052);
    pidBuiltinEndpointSet = Guard (p == 0x0058);
    pidBuiltinEndpointQos = Guard (p == 0x0077);
    pidPropertyList = Guard (p == 0x0059);
    pidTypeMaxSizeSerialized = Guard (p == 0x0060);
    pidEntityName = Guard (p == 0x0062);
    pidEndpointGuid = Guard (p == 0x005a);

    -- Table 9.15:
    pidContentFilterInfo = Guard (p == 0x0055);
    pidCoherentSet = Guard (p == 0x0056);
    pidDirectedWrite = Guard (p == 0x0057);
    pidOriginalWriterInfo = Guard (p == 0x0061);
    pidGroupCoherentSet = Guard (p == 0x0063);
    pidGroupSeqNum = @Guard (p == 0x0064);
    pidWriterGroupInfo = Guard (p == 0x0065);
    pidSecureWriterGroupInfo = Guard (p == 0x0066);
    pidKeyHash = Guard (p == 0x0070);
    pidStatusInfo = Guard (p == 0x0071);
  }
}

-- Table 9.13:
def ParameterIdValues littleEnd (pid: ParameterIdT) = Choose1 {
  padVal = {
    pid is pidPad;
    Many Octet;
  };
  -- sentinel: not allowed
  userDataVal = {
    pid is pidUserData;
    UserDataQosPolicy;
  };
  topicNameVal = {
    pid is pidTopicName;
    String256 littleEnd;
  };
  typeNameVal = {
    pid is pidTypeName;
    String256 littleEnd;
  };
  groupDataVal = {
    pid is pidGroupData;
    GroupDataQosPolicy;
  };
  topicDataVal = {
    pid is pidTopicData;
    TopicDataQosPolicy;
  };
  durabilityVal = {
    pid is pidDurability;
    DurabilityQosPolicy;
  };
  durabilityServiceVal = {
    pid is pidDurabilityService;
    DurabilityServiceQosPolicy;
  };
  deadlineVal = {
    pid is pidDeadline;
    DeadlineQosPolicy;
  };
  latencyBudgetVal = {
    pid is pidLatencyBudget;
    LatencyBudgetQosPolicy;
  };
  livelinessVal = {
    pid is pidLiveliness;
    LivenessQosPolicy;
  };
  reliabilityVal = {
    pid is pidReliability;
    ReliabilityQosPolicy;
  };
  lifespanVal = {
    pid is pidLifespan;
    LifespanQosPolicy;
  };
  destinationOrderVal = {
    pid is pidDestinationOrder;
    DestinationOrderQosPolicy;
  };
  historyVal = {
    pid is pidHistory;
    HistoryQosPolicy;
  };
  resourceLimitsVal = {
    pid is pidResourceLimits;
    ResourceLimitsQosPolicy;
  };
  ownershipVal = {
    pid is pidOwnership;
    OwnershipQosPolicy;
  };
  ownershipStrengthVal = {
    pid is pidOwnershipStrength;
    OwnershipStrengthQosPolicy;
  };
  presentationVal = {
    pid is pidPresentation;
    PresentationQosPolicy;
  };
  partitionVal = {
    pid is pidPartition;
    PartitionQosPolicy;
  };
  timeBasedFilterVal = {
    pid is pidTimeBasedFilter;
    TimeBasedFilterQosPolicy;
  };
  transportPriorityVal = {
    pid is pidTransportPriority;
    TransportPriorityQosPolicy;
  };
  domainIdVal = {
    pid is pidDomainId;
    DomainId littleEnd;
  };
  domainTagVal = {
    pid is pidDomainTag;
    String256 littleEnd;
  };
  protocolVersionVal = {
    pid is pidProtocolVersion;
    ProtocolVersion;
  };
  vendorIdVal = {
    pid is pidVendorId;
    VendorId;
  };
  unicastLocatorVal = {
    pid is pidUnicastLocator;
    Locator littleEnd;
  };
  multicastLocatorVal = {
    pid is pidMulticastLocator;
    Locator littleEnd;
  };
  defaultUnicastLocatorVal = {
    pid is pidDefaultUnicastLocator;
    Locator littleEnd;
  };
  multicastDefaultLocatorVal = {
    pid is pidDefaultMulticastLocator;
    Locator littleEnd;
  };
  metatrafficUnicastLocatorVal = {
    pid is pidMetatrafficUnicastLocator;
    Locator littleEnd;
  };
  metatrafficMulticastLocatorVal = {
    pid is pidMetatrafficMulticastLocator;
    Locator littleEnd;
  };
  expectsInlineQos = {
    pid is pidExpectsInlineQos;
    Boolean;
  };
  participantManualLivelinessCountVal = {
    pid is pidParticipantManualLivelinessCount;
    Count littleEnd;
  };
  participantLeaseDurationVal = {
    pid is pidParticipantLeaseDuration;
    Duration littleEnd;
  };
  contentFilterPropertyVal = {
    pid is pidContentFilterProperty;
    ContentFilterProperty littleEnd;
  };
  participantGUIDVal = {
    pid is pidParticipantGuid;
    GUIDT;
  };
  groupGUIDVal = {
    pid is pidGroupGuid;
    GUIDT;
  };
  builtinEndpointSetVal = {
    pid is pidBuiltinEndpointSet;
    BuiltinEndpointSetT;
  };
  buildtinEndpointQosVal = {
    pid is pidBuiltinEndpointQos;
    BuiltinEndpointQosT;
  };
  propertyListVal = {
    pid is pidPropertyList;
    Many PropertyT;
  };
  typeMaxSizeSerializedVal = {
    pid is pidTypeMaxSizeSerialized;
    EndULong littleEnd;
  };
  entityNameVal = {
    pid is pidEntityName;
    EntityName;
  };
  endpointGuidVal = {
    pid is pidEndpointGuid;
    GUIDT;
  };

  contentFilterInfoVal = {
    pid is pidContentFilterInfo;
    ContentFilterInfo littleEnd;
  };
  coherentSetVal = {
    pid is pidCoherentSet;
    SequenceNumber littleEnd;
  };
  directedWriteVal = {
    pid is pidDirectedWrite;
    GUIDT;
  };
  orignalWriterInfoVal = {
    pid is pidOriginalWriterInfo;
    OriginalWriterInfo littleEnd;
  };
  groupCoherentSetVal = {
    pid is pidGroupCoherentSet;
    SequenceNumber littleEnd;
  };
  groupSeqNumVal = {
    pid is pidGroupSeqNum;
    SequenceNumber littleEnd;
  };
  writerGroupInfoVal = {
    pid is pidWriterGroupInfo;
    WriterGroupInfo;
  };
  secureWriterGroupInfoVal = {
    pid is pidSecureWriterGroupInfo;
    WriterGroupInfo;
  };
  keyHashVal = {
    pid is pidKeyHash;
    KeyHash;
  };
  statusInfoVal = {
    pid is pidStatusInfo;
    StatusInfo;
  };
}

def ContentFilterInfo littleEnd = {
  numBitmaps = EndULong littleEnd;
  bitmaps = Many (numBitmaps as uint 64) (EndLong littleEnd);
  numSigs = EndULong littleEnd;
  signatures = Many (numSigs as uint 64) (FilterSignature littleEnd);
}

def OriginalWriterInfo littleEnd = {
  originalWriterGUID = GUIDT;
  originalWriterSN = SequenceNumber littleEnd;
}

def WriterGroupInfo = {
  writerSet = GroupDigest;
}

def FilterSignature littleEnd = Many 4 (EndLong littleEnd)

def KeyHash = Many 16 Octet

def StatusInfo = Many 4 Octet

-- relaxed definition. Refine as needed.
def UserDataQosPolicy = Many Octet

def BndString littleEnd n = {
  @len = EndULong littleEnd ;
  Guard (len <= n);
  $$ = Many (len as uint 64) Octet;
  Match1 0x00;
}

def String256 littleEnd = BndString littleEnd 256

-- relaxed definition. Refine as needed.
def GroupDataQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def TopicDataQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def DurabilityQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def DurabilityServiceQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def DeadlineQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def LatencyBudgetQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def LivenessQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def ReliabilityQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def LifespanQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def DestinationOrderQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def HistoryQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def ResourceLimitsQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def OwnershipQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def OwnershipStrengthQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def PresentationQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def PartitionQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def TimeBasedFilterQosPolicy = Many Octet

-- relaxed definition. Refine as needed.
def TransportPriorityQosPolicy = Many Octet

def ContentFilter = Many Octet

-- relaxed definition. Refine as needed.
def DomainId littleEnd = EndULong littleEnd

def Locator littleEnd = {
  kind = EndLong littleEnd;
  port = EndULong littleEnd;
  address = Many 16 Octet;
}

def LocatorList littleEnd = {
  numLocators = EndULong littleEnd;
  Many (numLocators as uint 64) (Locator littleEnd);
}

def LocatorUDPv4 littleEnd = {
  address = EndULong littleEnd;
  port = EndULong littleEnd;
}

def Count littleEnd = EndLong littleEnd

def Duration littleEnd = {
  seconds = EndLong littleEnd;
  fraction = EndULong littleEnd;
}

def ContentFilterProperty littleEnd = {
  contentFilteredTopicName = String256 littleEnd;
  relatedTopicName = String256 littleEnd;
  filterClassName = String256 littleEnd;
  filterExpression = String littleEnd;
  expressionParameters = Many String;
}

def Time littleEnd = {
  seconds = EndULong littleEnd;
  fraction = EndULong littleEnd;
}

def GUIDT = {
  guidPrefix = GuidPrefix;
  entityId = EntityId;
}

-- relaxed definition. Refine as needed.
def BuiltinEndpointSetT = Many Octet

-- relaxed definition. Refine as needed.
def BuiltinEndpointQosT = Many Octet

-- relaxed definition. Refine as needed.
def PropertyT = Many Octet

def EntityName = String

def Parameter littleEnd = {
  parameterId = ParameterIdT littleEnd;
  -- TODO: clean this up
  Guard (parameterId != {| pidSentinel = {} |});

  len = EndUShort littleEnd;
  Guard (len % 4 == 0);

  val = Chunk (len as uint 64) (ParameterIdValues littleEnd parameterId);
}

def Sentinel littleEnd = {
  @pId = ParameterIdT littleEnd;
  pId is pidSentinel;
  EndUShort littleEnd;
}

def ParameterList littleEnd = {
  $$ = Many (Parameter littleEnd);
  Sentinel littleEnd;
}

-- Sec 10 Serialized Payload Representation:
def SerializedPayload PayloadData qos = {
  payloadHeader = SerializedPayloadHeader;
  data = PayloadData qos;
}

def SerializedPayloadHeader = {
  representationIdentifier = Choose1 {
    userDefinedTopicData = Choose1 {
      cdrBe = @Match [0x00, 0x00];
      cdrLe = @Match [0x00, 0x01];
      plCdrBE = @Match [0x00, 0x02];
      plCdrLE = @Match [0x00, 0x03];
      cdr2Be = @Match [0x00, 0x10];
      cdr2LE = @Match [0x00, 0x11];
      plCdr2Be = @Match [0x00, 0x12];
      plCdr2LE = @Match [0x00, 0x03];
      dCdrBe = @Match [0x00, 0x14];
      dCdrLe = @Match [0x00, 0x15];
      xml = @Match [0x00, 0x04];
    };
  };
  representationOptions = OctetArray2;
}

-- Sec 9.3.2:
def FragmentNumber littleEnd = EndULong littleEnd

-- Sec 9.4.2.8:
def FragmentNumberSet littleEnd = {
  bitmapBase = FragmentNumber littleEnd;
  numBits = EndULong littleEnd;
  bitmap = Many ((numBits + 31)/32 as uint 64) (EndLong littleEnd);
}
