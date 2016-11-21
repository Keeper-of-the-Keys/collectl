#################################################### 
##  ___   ____       ____   ___  ## cs.huji.ac.il ##
## |   | /   /       \   \ |   | ##    /\         ##
## |   |/   /         \   \|   | ##   / /         ##
## |       /       __  \       | ##   \_/         ##
## |      /   ___ |  |_ \      | ##    _          ##
## |      \  / _ \|   _|/      | ##   | |  __  _  ##
## |       \/ / \ \  | /       | ##   | | /  \//  ##
## |   |\   \ \_/ /  |/   /|   | ##   | |/ /\ \   ##
## |___| \___\___/\__/___/ |___| ##   \_  /  \_\  ##
##      KeeperoftheKeys.nl       ##    /_/        ## 
####################################################

###############################################################################
# Derived from collectl/lexpr.ph by E.S. Rosenberg 5776/2016
# Original copyright, 2003-2009 Hewlett-Packard Development Company, LP
#
# Output collectl data to JSON on STDOUT
#
# @author: E.S. Rosenberg (Keeper of the Keys)
#          <esr+collectl at mail dot hebrew dot edu>
#
# TODO:
# - Implement Changes Only mode
# - Use TTL? Or remove it?
# - Remove some/all of the old debugging stuff.
# - disable/implement playback?
# - Add option to surpress "Waiting for X seconds and Ouch!"
###############################################################################

# Call with --export "json[,switches]
# Debug
#   1 - show all names/values, noting the timestamps are now!
#   2 - just show names/values 'sent'
#   4 - include real times in timestamps (useful for testing) along with skipped intervals
#   8 - do not send anything 
#       (useful when displaying normal output on terminal)
#  16 - show 'x' processing

our $jsonInterval;
my ($jsonSubsys, $jsonDebug, $jsonCOFlag, $jsonTTL, $jsonFilename, $jsonSumFlag);
my (%jsonDataLast, %jsonDataMin, %jsonDataMax, %jsonDataTot, %jsonTTL);
my ($jsonColInt, $jsonSendCount, $jsonFlags);
my ($jsonMinFlag, $jsonMaxFlag, $jsonAvgFlag, $jsonTotFlag)=(0,0,0,0);
my ($jsonPrettyFlag, $jsonIndividualFlag) = (0,0);
my $jsonOnePB=1024*1024*1024*1024*1024;
my $jsonSamples=0;
my $jsonOutputFlag=1;
my $jsonFirstInt=1;
my $jsonAlignFlag=0;
my $jsonCounter;
my $jsonExtName='';
my %jsonSample;

$jsonFlag   = (eval {require "JSON.pm" or die}) ? 1 : 0;
$roundFlag  = (eval {require "Math::Round" or die}) ? 1 : 0;
$scalarFlag = (eval {require "Scalar::Util qw(looks_like_number)" or die}) ? 1 : 0;
    
if(!$jsonFlag) {
  error('JSON.pm is required for this output module to work, exiting.');
  exit 1;
}

sub jsonInit
{
  error('json is an export, not an import')         if $import=~/json/;
  error('--showcolheader not supported by json')    if $showColFlag;

  # on the odd chance someone did -s-all and have other ways to generate data, collectl
  # hasn't yet hit the code that resets $subsys so we have to do it here.
  $subsys=''    if $userSubsys eq '-all';

  # Defaults for options
  $jsonDebug=$jsonCOFlag=0;
  $jsonFilename='';
  $jsonInterval='';
  $jsonSubsys=$subsys;
  $jsonTTL=5;

  foreach my $option (@_)
  {
    my ($name, $value)=split(/=/, $option, 2);   # in case more than 1 = in single option string
    error("invalid json option '$name'")    if $name!~/^[dfhisx]?$|^align$|^co$|^ttl$|^min$|^max$|^avg$|^tot$|^pretty$|^indiv$/;

    $jsonAlignFlag=1        if $name eq 'align';
    $jsonCOFlag=1           if $name eq 'co';
    $jsonDebug=$value       if $name eq 'd';
    $jsonFilename=$value    if $name eq 'f';
    $jsonInterval=$value    if $name eq 'i';
    $jsonSubsys=$value      if $name eq 's';
    $jsonExtName=$value     if $name eq 'x';
    $jsonTTL=$value         if $name eq 'ttl';
    $jsonMinFlag=1          if $name eq 'min';
    $jsonMaxFlag=1          if $name eq 'max';
    $jsonAvgFlag=1          if $name eq 'avg';
    $jsonTotFlag=1          if $name eq 'tot';
    $jsonPrettyFlag=1       if $name eq 'pretty';
    $jsonIndividualFlag=1   if $name eq 'indiv';

    help()                 if $name eq 'h';

    last    if $jsonExtName ne '';
  }

  # If importing data, and if not reporting anything else, $subsys will be ''
  $jsonSumFlag=$jsonSubsys=~/[cdfilmnstxE]/ ? 1 : 0;

  # s= disables ALL subsys, only makes sense with imports
  error("json subsys options '$jsonSubsys' not a proper subset of '$subsys'")
	    if $subsys ne '' && $jsonSubsys ne '' && $jsonSubsys!~/^[$subsys]+$/;
 
  error("json cannot write a snapshot file and use a socket at the same time")
	if $sockFlag && $jsonFilename ne '';

  # Using -f and f= will not result in raw or plot file so need this message.
  error ("using json option 'f=' AND -f requires -P and/or --rawtoo")
	if $jsonFilename ne '' && $filename ne '' && !$plotFlag && !$rawtooFlag;

  # if -f, use that dirname/L for snampshot file; otherwise use f= for it.
  $jsonFilename=(-d $filename) ? "$filename/L" : dirname($filename)."/L"
	if $jsonFilename eq '' && $filename ne '';

  $jsonFlags=$jsonMinFlag+$jsonMaxFlag+$jsonAvgFlag|$jsonTotFlag;
  error("only 1 of 'min', 'max', 'avg' or 'tot' with 'json'")    if $jsonFlags>1;

  # check for consistent intervals in interactive mode
  if ($playback eq '')
  {
    $jsonColInt=(split(/:/, $interval))[0];
    $jsonInterval=$jsonColInt    if $jsonInterval eq '';
    $jsonSendCount=int($jsonInterval/$jsonColInt);
    error("json interval of '$jsonInterval' is not a multiple of collectl interval of '$jsonColInt' seconds")
    		 if $jsonColInt*$jsonSendCount != $jsonInterval;
    error("'min', 'max', 'avg' & 'tot' require json 'i' that is > collectl's -i")
    		 if $jsonFlags && $jsonSendCount==1;

    if ($jsonAlignFlag)
    {
      my $div1=int(60/$jsonColInt);
      my $div2=int($jsonColInt/60);
      error("'align' requires collectl interval be a factor or multiple of 60 seconds")
      		     if ($jsonColInt<=60 && $div1*$jsonColInt!=60) || ($jsonColInt>60 && $div2*60!=$jsonColInt);
      error("'align' only makes sense when multiple samples/interval")	  if $jsonInterval<=$jsonColInt;
      error("'json,align' requires -D or --align")                       if !$alignFlag && !$daemonFlag;
    }
  }

  if ($jsonExtName ne '')
  {
    # build up swiches from EVERYTHING seen after x=
    my $xSeen=0;
    my $switches='';
    foreach my $option (@_)
    {
      $xSeen=1    if $option=~/^x/;
      $switches.="$option,"     if $xSeen && $option!~/^x/;
    }
    $switches=~s/,$//;

    ($jsonExtName, $switches)=(split(/:/, $jsonExtName, 2))[0,1]    if $jsonExtName=~/:/;    # backwards compatibility with : for switches
    $jsonExtBase=$jsonExtName;
    $jsonExtBase=~s/\..*//;    # in case extension
    $jsonExtName.='.ph'    if $jsonExtName!~/\./;
    #print "NAME: $jsonExtName  Switches: $switches\n";

    $tempName=$jsonExtName;   # name for error message before prepending with directory
    $jsonExtName="$ReqDir/$jsonExtName"    if !-e $jsonExtName;
    if (!-e "$jsonExtName")
    {
      my $temp="can't find json extension file '$tempName' in ./";
      $temp.=" OR $ReqDir/"    if $ReqDir ne '.';
      error($temp);
    }
    require $jsonExtName;
    print "$jsonExtName loaded\n"    if $jsonDebug & 16;

    # rather than pass an undefined switch, if not there don't pass anything
    my $initName="${jsonExtBase}Init";
    if (defined($switches))
    { 
      print "$initName($switches)\n"    if $jsonDebug & 16;
      &$initName($switches);
    }
    else
    { &$initName(); }
  }

  # need to reset here in case processing multiple files
  $jsonCounter=0;
} # End jsonInit

sub json {
  
  if ($jsonSubsys=~/c/i)
  {
    if ($jsonSubsys=~/c/)
    {
      # CPU utilization is a % and we don't want to report fractions
      my $i=$NumCpus;

      $jsonSample{'cputotals'}{'num'}   = setData('cputotals.num',   $i, 1);
      $jsonSample{'cputotals'}{'user'}  = setData('cputotals.user',  $userP[$i], 1);      
      $jsonSample{'cputotals'}{'nice'}  = setData('cputotals.nice',  $niceP[$i], 1);
      $jsonSample{'cputotals'}{'system'}= setData('cputotals.system',$sysP[$i], 1);
      $jsonSample{'cputotals'}{'wait'}  = setData('cputotals.wait',  $waitP[$i], 1);
      $jsonSample{'cputotals'}{'irq'}   = setData('cputotals.irq',   $irqP[$i], 1);
      $jsonSample{'cputotals'}{'soft'}  = setData('cputotals.soft',  $softP[$i], 1);
      $jsonSample{'cputotals'}{'steal'} = setData('cputotals.steal', $stealP[$i], 1);
      $jsonSample{'cputotals'}{'idle'}  = setData('cputotals.idle',  $idleP[$i], 1);

      # These 2 are redundant, but also handy
      $jsonSample{'cputotals'}{'systot'} = setData('cputotals.systot',  $sysP[$i]+$irqP[$i]+$softP[$i]+$stealP[$i], 1);
      $jsonSample{'cputotals'}{'usertot'} = setData('cputotals.usertot', $userP[$i]+$niceP[$i], 1);
      $jsonSample{'cputotals'}{'total'} = setData('cputotals.total',   $sysP[$i]+$irqP[$i]+$softP[$i]+$stealP[$i]+$userP[$i]+$niceP[$i], 1);
    }

    if ($jsonSubsys=~/C/)
    {
      for (my $i=0; $i<$NumCpus; $i++)
      {
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'user'}   = setData('cpuinfo.user.cpu'.$i,   $userP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'nice'}   = setData('cpuinfo.nice.cpu'.$i,   $niceP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'sys'}    = setData('cpuinfo.sys.cpu'.$i,    $sysP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'wait'}   = setData('cpuinfo.wait.cpu'.$i,   $waitP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'irq'}    = setData('cpuinfo.irq.cpu'.$i,    $irqP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'soft'}   = setData('cpuinfo.soft.cpu'.$i,   $softP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'steal'}  = setData('cpuinfo.steal.cpu'.$i,  $stealP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'idle'}   = setData('cpuinfo.idle.cpu'.$i,   $idleP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'intrpt'} = setData('cpuinfo.intrpt.cpu'.$i, $intrptTot[$i], 1);

	# sys and user can be useful too
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'systot'}  = setData('cputotals.systot.cpu'.$i,  $sysP[$i]+$irqP[$i]+$softP[$i]+$stealP[$i], 1);
        $jsonSample{'cpuinfo'}{'cpu'.$i}{'usertot'} = setData('cputotals.usertot.cpu'.$i, $userP[$i]+$niceP[$i], 1);
      }
    }
    # General CPU info important regardless of detail level.
    $jsonSample{'ctxint'}{'ctx'} = setData('ctxint.ctx',  $ctxt/$intSecs);
    $jsonSample{'ctxint'}{'int'} = setData('ctxint.int',  $intrpt/$intSecs);

    $jsonSample{'proc'}{'creates'} = setData('proc.creates', $proc/$intSecs);
    $jsonSample{'proc'}{'runq'}    = setData('proc.runq',    $loadQue, 1);
    $jsonSample{'proc'}{'run'}     = setData('proc.run',     $loadRun, 1);

    $jsonSample{'cpuload'}{'avg1'}  = setData('cpuload.avg1',  $loadAvg1, 1, '%4.2f');
    $jsonSample{'cpuload'}{'avg5'}  = setData('cpuload.avg5',  $loadAvg5, 1, '%4.2f');
    $jsonSample{'cpuload'}{'avg15'} = setData('cpuload.avg15', $loadAvg15, 1,'%4.2f');
    if ($NumCpus > 1){
      $jsonSample{'cpuload'}{'norm'}{'avg1'}  = setData('cpuload.avg1',  $loadAvg1/$NumCpus, 1, '%4.2f');
      $jsonSample{'cpuload'}{'norm'}{'avg5'}  = setData('cpuload.avg5',  $loadAvg5/$NumCpus, 1, '%4.2f');
      $jsonSample{'cpuload'}{'norm'}{'avg15'} = setData('cpuload.avg15', $loadAvg15/$NumCpus, 1,'%4.2f');
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'cpu';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/d/i)
  {
    if ($jsonSubsys=~/d/)
    {
      $jsonSample{'disktotals'}{'reads'}    = setData('disktotals.reads',    $dskReadTot/$intSecs);
      $jsonSample{'disktotals'}{'readkbs'}  = setData('disktotals.readkbs',  $dskReadKBTot/$intSecs);
      $jsonSample{'disktotals'}{'writes'}   = setData('disktotals.writes',   $dskWriteTot/$intSecs);
      $jsonSample{'disktotals'}{'writekbs'} = setData('disktotals.writekbs', $dskWriteKBTot/$intSecs);
    }

    if ($jsonSubsys=~/D/)
    {
      for (my $i=0; $i<@dskOrder; $i++)
      {
        # preserve display order but skip any disks not seen this interval
        $dskName=$dskOrder[$i];
        next    if !defined($dskSeen[$i]);
        next    if ($dskFiltKeep eq '' && $dskName=~/$dskFiltIgnore/) || ($dskFiltKeep ne '' && $dskName!~/$dskFiltKeep/);

        $jsonSample{'diskinfo'}{$dskName}{'reads'}    = setData('diskinfo.reads.'.$dskName,    $dskRead[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'readkbs'}  = setData('diskinfo.readkbs.'.$dskName,  $dskReadKB[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'readw'}    = setData('diskinfo.readw.'.$dskName,    $dskWaitR[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'writes'}   = setData('diskinfo.writes.'.$dskName,   $dskWrite[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'writekbs'} = setData('diskinfo.writekbs.'.$dskName, $dskWriteKB[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'writew'}   = setData('diskinfo.writew.'.$dskName,   $dskWaitW[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'quelen'}   = setData('diskinfo.quelen.'.$dskName,   $dskQueLen[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'wait'}     = setData('diskinfo.wait.'.$dskName,     $dskWait[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'svctime'}  = setData('diskinfo.svctime.'.$dskName,  $dskSvcTime[$i]/$intSecs);
        $jsonSample{'diskinfo'}{$dskName}{'util'}     = setData('diskinfo.util.'.$dskName,     $dskUtil[$i]/$intSecs);
      }
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'diskio';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/f/)
  {
    if ($nfsSFlag)
    {
      $jsonSample{'nfsinfo'}{'server'}{'read'}   = setData('nfsinfo.Sread',  $nfsSReadsTot/$intSecs);
      $jsonSample{'nfsinfo'}{'server'}{'write'}  = setData('nfsinfo.Swrite', $nfsSWritesTot/$intSecs);
      $jsonSample{'nfsinfo'}{'server'}{'meta'}   = setData('nfsinfo.Smeta',  $nfsSMetaTot/$intSecs);
      $jsonSample{'nfsinfo'}{'server'}{'commit'} = setData('nfsinfo.Scommit',$nfsSCommitTot/$intSecs);
    }
    if ($nfsCFlag)
    {
      $jsonSample{'nfsinfo'}{'client'}{'read'}   = setData('nfsinfo.Cread',  $nfsCReadsTot/$intSecs);
      $jsonSample{'nfsinfo'}{'client'}{'write'}  = setData('nfsinfo.Cwrite', $nfsCWritesTot/$intSecs);
      $jsonSample{'nfsinfo'}{'client'}{'meta'}   = setData('nfsinfo.Cmeta',  $nfsCMetaTot/$intSecs);
      $jsonSample{'nfsinfo'}{'client'}{'commit'} = setData('nfsinfo.Ccommit',$nfsCCommitTot/$intSecs);
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'nfs';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/i/)
  {
    $jsonSample{'inodeinfo'}{'dentrynum'}    = setData('inodeinfo.dentrynum',    $dentryNum, 1);
    $jsonSample{'inodeinfo'}{'dentryunused'} = setData('inodeinfo.dentryunused', $dentryUnused, 1);
    $jsonSample{'inodeinfo'}{'filesalloc'}   = setData('inodeinfo.filesalloc',   $filesAlloc, 1);
    $jsonSample{'inodeinfo'}{'filesmax'}     = setData('inodeinfo.filesmax',     $filesMax, 1);
    $jsonSample{'inodeinfo'}{'inodeused'}    = setData('inodeinfo.inodeused',    $inodeUsed, 1);
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'inodes';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/l/)
  {
    if ($CltFlag)
    {
      $jsonSample{'lustre'}{'client'}{'reads'}    = setData('lusclt.reads',    $lustreCltReadTot/$intSecs);
      $jsonSample{'lustre'}{'client'}{'readkbs'}  = setData('lusclt.readkbs',  $lustreCltReadKBTot/$intSecs);
      $jsonSample{'lustre'}{'client'}{'writes'}   = setData('lusclt.writes',   $lustreCltWriteTot/$intSecs);
      $jsonSample{'lustre'}{'client'}{'writekbs'} = setData('lusclt.writekbs', $lustreCltWriteKBTot/$intSecs);
      $jsonSample{'lustre'}{'client'}{'numfs'}    = setData('lusclt.numfs',    $NumLustreFS, 1);
    }

    if ($MdsFlag)
    {
      my $getattrPlus=$lustreMdsGetattr+$lustreMdsGetattrLock+$lustreMdsGetxattr;
      my $setattrPlus=$lustreMdsReintSetattr+$lustreMdsSetxattr;
      my $varName=($cfsVersion lt '1.6.5') ? 'reint' : 'unlink';
      my $varVal= ($cfsVersion lt '1.6.5') ? $lustreMdsReint : $lustreMdsReintUnlink;

      $jsonSample{'lustre'}{'mds'}{'gattrP'} = setData('lusmds.gattrP',    $getattrPlus/$intSecs);
      $jsonSample{'lustre'}{'mds'}{'sattrP'} = setData('lusmds.sattrP',    $setattrPlus/$intSecs);
      $jsonSample{'lustre'}{'mds'}{'sync'}   = setData('lusmds.sync',      $lustreMdsSync/$intSecs);
      $jsonSample{'lustre'}{'mds'}{$varName} = setData('lusmds.'.$varName, $varVal/$intSecs);
    }

    if ($OstFlag)
    {
      $jsonSample{'lustre'}{'ost'}{'reads'}    = setData('lusost.reads',    $lustreReadOpsTot/$intSecs);
      $jsonSample{'lustre'}{'ost'}{'readkbs'}  = setData('lusost.readkbs',  $lustreReadKBytesTot/$intSecs);
      $jsonSample{'lustre'}{'ost'}{'writes'}   = setData('lusost.writes',   $lustreWriteOpsTot/$intSecs);
      $jsonSample{'lustre'}{'ost'}{'writekbs'} = setData('lusost.writekbs', $lustreWriteKBytesTot/$intSecs);
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'lustre';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/m/i)
  {
    if ($jsonSubsys=~/m/)
    {
      $jsonSample{'meminfo'}{'total'}	   = setData('meminfo.tot',        $memTot, 1);
      $jsonSample{'meminfo'}{'used'}   	   = setData('meminfo.used', 	   $memUsed, 1);
      $jsonSample{'meminfo'}{'free'}   	   = setData('meminfo.free', 	   $memFree, 1);
      $jsonSample{'meminfo'}{'shared'} 	   = setData('meminfo.shared', 	   $memShared, 1);
      $jsonSample{'meminfo'}{'buffer'} 	   = setData('meminfo.buf', 	   $memBuf, 1);
      $jsonSample{'meminfo'}{'cached'} 	   = setData('meminfo.cached', 	   $memCached, 1);
      $jsonSample{'meminfo'}{'slab'}   	   = setData('meminfo.slab', 	   $memSlab, 1);
      $jsonSample{'meminfo'}{'map'}    	   = setData('meminfo.map', 	   $memMap, 1);
      $jsonSample{'meminfo'}{'anon'}   	   = setData('meminfo.anon', 	   $memAnon, 1);
      $jsonSample{'meminfo'}{'anonH'}  	   = setData('meminfo.anonH',	   $memAnonH, 1);
      $jsonSample{'meminfo'}{'dirty'}      = setData('meminfo.dirty', 	   $memDirty, 1);
      $jsonSample{'meminfo'}{'locked'}     = setData('meminfo.locked', 	   $memLocked, 1);
      $jsonSample{'meminfo'}{'inactive'}   = setData('meminfo.inactive',   $memInact, 1);
      $jsonSample{'meminfo'}{'hugetot'}    = setData('meminfo.hugetot',    $memHugeTot, 1);
      $jsonSample{'meminfo'}{'hugefree'}   = setData('meminfo.hugefree',   $memHugeFree, 1);
      $jsonSample{'meminfo'}{'hugersvd'}   = setData('meminfo.hugersvd',   $memHugeRsvd, 1);
      $jsonSample{'meminfo'}{'sunreclaim'} = setData('meminfo.sunreclaim', $memSUnreclaim, 1);
      $jsonSample{'swapinfo'}{'total'} 	   = setData('swapinfo.total', 	   $swapTotal, 1);
      $jsonSample{'swapinfo'}{'free'} 	   = setData('swapinfo.free', 	   $swapFree, 1);
      $jsonSample{'swapinfo'}{'used'} 	   = setData('swapinfo.used', 	   $swapUsed, 1);
      $jsonSample{'swapinfo'}{'in'} 	   = setData('swapinfo.in', 	   $swapin/$intSecs);
      $jsonSample{'swapinfo'}{'out'} 	   = setData('swapinfo.out', 	   $swapout/$intSecs);
      $jsonSample{'pageinfo'}{'fault'} 	   = setData('pageinfo.fault', 	   $pagefault/$intSecs);
      $jsonSample{'pageinfo'}{'majfault'}  = setData('pageinfo.majfault',  $pagemajfault/$intSecs);
      $jsonSample{'pageinfo'}{'in'} 	   = setData('pageinfo.in', 	   $pagein/$intSecs);
      $jsonSample{'pageinfo'}{'out'} 	   = setData('pageinfo.out', 	   $pageout/$intSecs);
    }

    if ($jsonSubsys=~/M/)
    {
      for (my $i=0; $i<$CpuNodes; $i++)
      {
        foreach my $field ('used', 'free', 'slab', 'map', 'anon', 'anonH', 'lock', 'act', 'inact')
        {
          $jsonSample{'numainfo'}{$i}{$field} = setData('numainfo.'.$field.'.'.$i, $numaMem[$i]->{$field}, 1);
        }
      }
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'memory';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/n/i)
  {
    if ($jsonSubsys=~/n/)
    {
      $jsonSample{'nettotals'}{'kbin'}   = setData('nettotals.kbin',   $netRxKBTot/$intSecs);
      $jsonSample{'nettotals'}{'pktin'}  = setData('nettotals.pktin',  $netRxPktTot/$intSecs);
      $jsonSample{'nettotals'}{'kbout'}  = setData('nettotals.kbout',  $netTxKBTot/$intSecs);
      $jsonSample{'nettotals'}{'pktout'} = setData('nettotals.pktout', $netTxPktTot/$intSecs);
    }

    if ($jsonSubsys=~/N/)
    {
      for ($i=0; $i<@netOrder; $i++)
      {
        $netName=$netOrder[$i];
        next    if !defined($netSeen[$i]);
        next    if ($netFiltKeep eq '' && $netName=~/$netFiltIgnore/) || ($netFiltKeep ne '' && $netName!~/$netFiltKeep/);
        next    if $netName=~/lo|sit/;

        $jsonSample{'netinfo'}{$netName}{'kbin'}   = setData('netinfo.kbin.$netName',   $netRxKB[$i]/$intSecs);
        $jsonSample{'netinfo'}{$netName}{'pktin'}  = setData('netinfo.pktin.$netName',  $netRxPkt[$i]/$intSecs);
        $jsonSample{'netinfo'}{$netName}{'kbout'}  = setData('netinfo.kbout.$netName',  $netTxKB[$i]/$intSecs);
        $jsonSample{'netinfo'}{$netName}{'pktout'} = setData('netinfo.pktout.$netName', $netTxPkt[$i]/$intSecs);
      }
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'network';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/s/)
  {
    $jsonSample{'sockinfo'}{'used'}   = setData('sockinfo.used', $sockUsed, 1);
    $jsonSample{'sockinfo'}{'tcp'}    = setData('sockinfo.tcp', $sockTcp, 1);
    $jsonSample{'sockinfo'}{'orphan'} = setData('sockinfo.orphan', $sockOrphan, 1);
    $jsonSample{'sockinfo'}{'tw'}     = setData('sockinfo.tw', $sockTw, 1);
    $jsonSample{'sockinfo'}{'alloc'}  = setData('sockinfo.alloc', $sockAlloc, 1);
    $jsonSample{'sockinfo'}{'mem'}    = setData('sockinfo.mem', $sockMem, 1);
    $jsonSample{'sockinfo'}{'udp'}    = setData('sockinfo.udp', $sockUdp, 1);
    $jsonSample{'sockinfo'}{'raw'}    = setData('sockinfo.raw', $sockRaw, 1);
    $jsonSample{'sockinfo'}{'frag'}   = setData('sockinfo.frag', $sockFrag, 1);
    $jsonSample{'sockinfo'}{'fragm'}  = setData('sockinfo.fragm', $sockFragM, 1);
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'sockets';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/t/)
  {
    $jsonSample{'tcpinfo'}{'iperrs'}   = setData('tcpinfo.iperrs',   $ipErrors/$intSecs)       if $tcpFilt=~/i/;
    $jsonSample{'tcpinfo'}{'tcperrs'}  = setData('tcpinfo.tcperrs',  $tcpErrors/$intSecs)      if $tcpFilt=~/t/;
    $jsonSample{'tcpinfo'}{'udperrs'}  = setData('tcpinfo.udperrs',  $udpErrors/$intSecs)      if $tcpFilt=~/u/;
    $jsonSample{'tcpinfo'}{'icmperrs'} = setData('tcpinfo.icmperrs', $icmpErrors/$intSecs)     if $tcpFilt=~/c/;
    $jsonSample{'tcpinfo'}{'tcpxerrs'} = setData('tcpinfo.tcpxerrs', $tcpExErrors/$intSecs)    if $tcpFilt=~/T/;
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'tcp';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/x/i)
  {
    if ($NumHCAs)
    {
      if ($jsonSubsys=~/x/)
      {
        $kbInT=  $ibRxKBTot;
        $pktInT= $ibRxTot;
        $kbOutT= $ibTxKBTot;
        $pktOutT=$ibTxTot;

        $jsonSample{'iconnect'}{'kbin'}   = setData('iconnect.kbin',   $kbInT/$intSecs);
        $jsonSample{'iconnect'}{'pktin'}  = setData('iconnect.pktin',  $pktInT/$intSecs);
        $jsonSample{'iconnect'}{'kbout'}  = setData('iconnect.kbout',  $kbOutT/$intSecs);
        $jsonSample{'iconnect'}{'pktout'} = setData('iconnect.pktout', $pktOutT/$intSecs);
      }

      if ($jsonSubsys=~/X/)
      {
        for (my $i=0; $i<$NumHCAs; $i++)
	{
	  $HCAName[$i]=~/(\S+?)_*$/;
	  #print 'HCA: $HCAName[$i]  1: $1\n';
	  $jsonSample{'iconnect'}{$i}{'name'}   = "HCA: $HCAName[$i]  1: $1";
	  $jsonSample{'iconnect'}{$i}{'kbin'}   = setData('iconnect.'.$1.'.kbin',   $ibRxKB[$i]/$intSecs);
          $jsonSample{'iconnect'}{$i}{'pktin'}  = setData('iconnect.'.$1.'.pktin',  $ibRx[$i]/$intSecs);
          $jsonSample{'iconnect'}{$i}{'kbout'}  = setData('iconnect.'.$1.'.kbout',  $ibTxKB[$i]/$intSecs);
          $jsonSample{'iconnect'}{$i}{'pktout'} = setData('iconnect.'.$1.'.pktout', $ibTx[$i]/$intSecs);
        }
      }
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'infiniband';
      outputAndResetSample();
    }
  }

  if ($jsonSubsys=~/E/i)
  {
    foreach $key (sort keys %$ipmiData)
    {
      for (my $i=0; $i<scalar(@{$ipmiData->{$key}}); $i++)
      {
        my $name=$ipmiData->{$key}->[$i]->{name};
        my $inst=($key!~/power/ && $ipmiData->{$key}->[$i]->{inst} ne '-1') ? $ipmiData->{$key}->[$i]->{inst} : '';
	
	my $format;
	if($scalarFlag) {
	  $format = looks_like_number($ipmiData->{$key}->[$i]->{value}) ? '' : '%s';
	} elsif ($ipmiData->{$key}->[$i]->{value} =~ /^[0-9,.E]+$/ ) {
	  $format = '%d';
	} else {
	  $format = '%s';
	}
	
        $jsonSample{'env'}{$name.$inst} = setData('env.'.$name.$inst, $ipmiData->{$key}->[$i]->{value}, 1, $format);
      }
    }
    if ($jsonIndividualFlag) {
      $jsonSample{'metricset'} = 'environment';
      outputAndResetSample();
    }
  }
  if (!$jsonIndividualFlag) {
    outputAndResetSample();
  }
} # End json

sub outputAndResetSample {
  my $output;
  $jsonSample{'timestamp'} = $lastSecs[$rawPFlag];

  if ($jsonPrettyFlag) {
    $output = JSON->new->utf8->pretty->allow_nonref->encode(\%jsonSample)."\n";
  } else {
    $output = JSON->new->utf8->allow_nonref->encode(\%jsonSample)."\n";
  }

  if ($sockFlag || $jsonFilename eq '') {
    printText($output, 1);
  } elsif ($jsonFilename ne '') {
    open  EXP, ">>$jsonFilename" or logmsg("F", "Couldn't create '$jsonFilename'");
    print EXP  $output;
    close EXP;
  }
  
  %jsonSample = ();
}

sub setData {
  my $name  = shift;
  my $value = shift;
  my $gauge = shift;
  my $format= shift;

  # These are only undefined the very first time
  if (!defined($jsonTTL{$name})) {
    $jsonTTL{$name}=$jsonTTL;
    $jsonDataLast{$name}=-1;
  }

  # As a minor optimization, only do this when dealing with min/max/avg/tot values
  if ($jsonFlags) {
    # And while this should be done in init(), we really don't know how may indexes
    # there are until our first pass through...
    if ($jsonSamples==1)
    {
      $jsonDataMin{$name}=$jsonOnePB;
      $jsonDataMax{$name}=0;
      $jsonDataTot{$name}=0;
    }

    $jsonDataMin{$name}=$value    if $jsonMinFlag && $value<$jsonDataMin{$name};
    $jsonDataMax{$name}=$value    if $jsonMaxFlag && $value>$jsonDataMax{$name};
    $jsonDataTot{$name}+=$value   if $jsonAvgFlag;

    # totals are a little different.  In the case of rates, we need to multiply by the collectl
    # interval to get the interval total, but for gauges we're really only doing averages
    $jsonDataTot{$name}+=(!$gauge) ? $value*$jsonColInt : $value    if $jsonTotFlag;
  }

  # If doing min/max/avg, reset $value
  if ($jsonFlags)
  {
    $value=$jsonDataMin{$name}                    if $jsonMinFlag;
    $value=$jsonDataMax{$name}                    if $jsonMaxFlag;
    $value=$jsonDataTot{$name}                    if $jsonTotFlag;
    $value=$jsonDataTot{$name}/$jsonSamples       if $jsonAvgFlag || defined($gauge);    # gauges are reported as averages
  }

  # No Change Only mode/TTL for JSON (at least for now)
  $format ='%d'    if !defined($format);
  $value += 0      if $format=~/d/;
  if ($roundFlag) {
    $value = nearest(0.01, $value);
  } elsif ($format !~ /s/) {
    $value = round($value, 2);
  }
  $jsonDataLast{$name} = $value;

  return(defined($returnValue) ? $returnValue : $value);
} # End setData

sub round {
  my ($nr, $decimals) = @_;
  return (-1)*(int(abs($nr)*(10**$decimals) +.5 ) / (10**$decimals)) if $nr<0;
  return int( $nr*(10**$decimals) +.5 ) / (10**$decimals);
}

sub help {
  my $text=<<EOF;

usage: --export=json[,options]
  where each option is separated by a comma, noting some take args themselves
    align       align output to whole minute boundary
    co          only reports changes since last reported value (not implented)
    d=mask      debugging options, see beginning of graphite.ph for details
    f=file      log filename
    h           print this help and exit
    i=seconds   reporting interval, must be multiple of collect's -i
    s=subsys    only report subsystems, must be a subset of collectl's -s
    ttl=num     if data hasn't changed for this many intervals, report it
                only used with 'co', def=5
    x=file      do a 'require' on specified file to extend json functionality
    avg         report average of values since last report    
    max         report maximum value since last report
    min         report minimal value since last report
    tot		report total values (as makes sense) since last report
    pretty      output 'pretty' JSON spread over multiple lines, machine consumers may not like this
    indiv       output a separate json object for each metric set
EOF

  print $text;
  exit(0);
} # End help

1;
