# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# NOTE: If you're wondering about all the var xyz = p.key:
# https://github.com/nim-lang/Nim/issues/2314


import
  logging,
  json,
  nre,
  os,
  ospaths,
  osproc,
  options,
  parseopt,
  posix,
  random,
  sets,
  sequtils,
  std/sha1,
  streams,
  strformat,
  strutils,
  tables,
  terminal,
  times,
  typetraits


when not fileExists "build/config.nim":
  {.fatal: "You must run 'nimble config' before building".}

include ../build/config


const
  InternalVerboseArg = "--bluecap-internal-verbose"

  CapsuleRegex = r"^[0-9a-zA-Z_.\-]+$"

  PolkitRulesPath = ConfigSysconfdir / "polkit-1/rules.d/49-bluecap.rules"
  EtcStoragePath = ConfigSysconfdir / "bluecap"
  EtcDefaultsJsonPath = EtcStoragePath / "defaults.json"
  GlobalStoragePath = ConfigSharedstatedir / "bluecap"
  GlobalCapsulesPath = GlobalStoragePath / "capsules"
  GlobalExportsPath = GlobalStoragePath / "exports"
  GlobalExportsBinPath = GlobalExportsPath / "bin"
  GlobalPolkitTrustedPath = GlobalStoragePath / "polkit-trusted.json"
  GlobalPersistencePath = GlobalStoragePath / "persistence"
  UserPersistenceChild = ".local" / "share" / "bluecap" / "persistence"

  RulesJs = """// THIS FILE IS AUTOMATICALLY GENERATED by bluecap
// Do NOT edit: your changes will be overwritten!

var TRUSTED = <TRUSTED>

polkit.addRule(function (action, subject) {
    if (action.id == 'com.refi64.Bluecap.run') {
        var cmdline = action.lookup('command_line')
        var capsule = cmdline.match(/su-run (\S+)/)[1]
        polkit.log('bluecap:' + capsule)
        if (!capsule.match(/<REGEX>/))
            return polkit.Result.NO
        if (TRUSTED.hasOwnProperty(capsule))
            return polkit.Result.YES
    }

    return polkit.Result.NOT_HANDLED
});"""


type
  Action {.pure.} = enum
    Version, Create, Delete, Trust, OptionsModify, OptionsDump, Persistence, Run, Export,
    SuCreate, SuDelete, SuTrust, SuOptionsModify, SuPersistence, SuRun, SuExport, Link

  CapsuleInfo = object
    name: string
    path: string
    rootless: bool

  Command = object
    synop: string
    help: string
    call: proc (p: var OptParser)

  InvalidEnumValue = object of Exception

  DefaultsJson = object
    options: seq[string]

  CapsuleJson = object
    image: string
    options: seq[string]
    # XXX: Option for compatibility reasons
    persistence: seq[string]

  TrustedJson = object
    trusted: seq[string]


var
  gVerbose = false
  gRootless = false


proc die(s: string) {.noreturn.} =
  stderr.writeLine s
  quit 1

proc dieCapsuleRequired() {.noreturn.} = die "A capsule is required."
proc dieInvalidOption(arg: string) {.noreturn.} = die "Invalid option: " & arg
proc dieTooManyArgs() {.noreturn.} = die "Too many arguments."


proc printWrapped(left, right: string) =
  let prefix = left & "  "
  let termWidth = terminalWidth()
  let rightWidth = termWidth - prefix.len

  if right.len <= rightWidth:
    echo prefix & right
  else:
    stdout.write prefix
    var lineWidth = 0

    for part in right.splitWhitespace:
      if lineWidth + part.len + 1 >= rightWidth:
        stdout.write "\n" & spaces(prefix.len)
        lineWidth = 0

      if lineWidth != 0:
        stdout.write " "
        lineWidth += 1

      stdout.write part
      lineWidth += part.len

    echo ""

template walkOpts(p: typed, actions: untyped) =
  while p.kind != cmdEnd:
    debug fmt"walkOpts: kind = {p.kind}, key = {p.key}, val = {p.val}"
    actions
    p.next

proc assignToFirstNone[T](value: T, args: varargs[ptr Option[T]]): bool =
  for arg in args:
    if arg[].isNone:
      arg[] = some value
      return true

  return false

proc writeFileAtomic(filename, content: string) =
  let atomicFilename = filename & ".atomic"
  writeFile atomicFilename, content
  moveFile atomicFilename, filename

proc camelToDash(s: string): string =
  result = newStringOfCap(s.len * 2)

  for i in 0..<s.len:
    if s[i].isUpperAscii and i != 0:
      result.add '-' & s[i].toLowerAscii
    else:
      result.add s[i].toLowerAscii

proc parseDashEnum[T: enum](s: string): T =
  for e in low(T)..high(T):
    if ($e).camelToDash == s:
      return e

  raise newException(InvalidEnumValue, s)

proc uniqueValue(): string =
  # A "good-enough" unique value generator for container names.
  let salt = rand(high(int) div 2) + high(int) div 2
  return ($secureHash($getTime().utc & $salt))[0..7].toLower

proc mergeUnsorted[T](a: openarray[T], b: openarray[T], inverse: bool = false): seq[T] =
  var s = initSet[T]()
  s.incl a.toSet

  if not inverse:
    s.incl b.toSet
  else:
    s.excl b.toSet

  return sequtils.toSeq s.items

proc existsOrCreateDirWithParents(path: string): bool =
  for dir in path.parentDirs(fromRoot = true):
    discard existsOrCreateDir dir

  return existsOrCreateDir path

proc replaceProcess(command: string, args: seq[string]) =
  var args2 = @[command]
  args2.add args

  debug "Going to execvp: " & quoteShellCommand(args2)

  discard execvp(command, allocCStringArray(args2))
  die fmt"execvp failed: {strerror(errno)}"

proc getOriginalUid(): string =
  if getuid() == 0:
    # HACK: Order is important due to the double-root spawn in suAction (see comment
    # in Action.Run's command handler for more info).
    for env in ["SUDO_UID", "PKEXEC_UID"]:
      result = getEnv env
      if result.len != 0:
        debug fmt"Got original UID {result} from {env}"
        return

    debug "Running as UID 0, but could not find an original UID"

  return $getuid()

proc getOriginalHome(): string =
  let uid = Uid(parseUInt(getOriginalUid()))
  if uid == getuid():
    return getHomeDir()

  let passwd = getpwuid uid
  result = $passwd.pw_dir
  debug "UID is not the same, original home dir: " & result

proc removePathPrefix(path, prefix: string): string =
  assert path.startsWith prefix
  result = path
  removePrefix result, prefix
  removePrefix result, '/'

proc checkUnderHome(dir, home: string): string {.discardable.} =
  var resolvedHome = expandFilename home
  if not dir.startsWith resolvedHome:
    debug fmt"checkUnderHome: resolvedHome = {resolvedHome}, dir = {dir}"
    die fmt"Working directory {dir} is not under your home directory."

  return removePathPrefix(dir, resolvedHome)

proc resolveCapsuleInfo(name: string, shouldExist: bool): CapsuleInfo =
  if name == ".":
    for parent in parentDirs getCurrentDir():
      let default = parent / ".bluecap" / "default.json"
      if fileExists default:
        result.path = expandSymlink default
        result.name = splitFile(result.path)[1]
        break

    if result.name.len == 0:
      die "No capsule has been linked."
  else:
    result.name = name
    result.path = (GlobalCapsulesPath / name) & ".json"

  result.rootless = not result.path.startsWith GlobalCapsulesPath

  if not result.name.contains re(CapsuleRegex):
    die fmt"Invalid capsule name: {result.name}"

  if shouldExist and not fileExists result.path:
    die fmt"Capsule {name} does not exist."
  elif not shouldExist and fileExists result.path:
    die fmt"Capsule {name} already exists."

proc getPersistenceRoot(capsule: string): string =
  let uid = parseUInt(getOriginalUid())
  debug fmt"Original uid: {uid}"
  let base =
    if uid == 0:
      GlobalPersistencePath
    else:
      getOriginalHome() / UserPersistenceChild
  return base / capsule

var commands = initOrderedTable[Action, Command]()

proc showHelp() =
  echo "bluecap [-?|-h|--help] [-v|--verbose] COMMAND CAPSULE [ARGS...]"
  echo ""
  echo "Commands:"

  var longest = 0
  for command in commands.values:
    if command.synop.len >= longest:
      longest = command.synop.len

  printWrapped ("  " & "help".alignLeft(longest)), "Show this screen"
  for command in commands.values:
    if command.synop.len > 0:
      printWrapped ("  " & command.synop.alignLeft(longest)), command.help

  quit()

proc makeCommand(action: Action, synop, help: string = "", call: proc (p: var OptParser)) =
  commands[action] = Command(synop: synop, help: help, call: call)

proc suAction(action: Action, args: seq[string]) =
  # HACK: See comment in Action.Run's command handler.
  if getuid() == 0 and action != Action.SuRun:
    debug fmt"suAction skipping pkexec: {action} {quoteShellCommand(args)}"
    var p = initOptParser args
    p.next
    commands[action].call p
    quit()
  else:
    if gRootless:
      putEnv "BLUECAP_ROOTLESS", "1"

    var runArgs = newSeqOfCap[string] args.len + 2

    # Don't actually use pkexec if gRootless
    if not gRootless:
      runArgs.add getAppFilename()

    runArgs.add camelToDash($action)
    runArgs.add args
    if gVerbose:
      runArgs.add InternalVerboseArg

    if action == Action.SuRun and getuid() == 0:
      # HACK: see above
      let sudoUid = getEnv "SUDO_UID"
      if sudoUid.len > 0:
        runArgs.insert "env"
        runArgs.insert fmt"SUDO_UID={sudoUid}", 1

    if gRootless:
      replaceProcess(getAppFilename(), args = runArgs)
    else:
      replaceProcess("pkexec", args = runArgs)

makeCommand(Action.Version, "version", "Show bluecap version and config") do (p: var OptParser):
  echo fmt"bluecap {Version}"
  echo fmt"sysconfdir     : {ConfigSysconfdir}"
  echo fmt"sharedstatedir : {ConfigSharedstatedir}"

makeCommand(Action.Create, "create ... IMAGE",
            "Create a capsule from the given image") do (p: var OptParser):
  var capsule: Option[string]
  var image: Option[string]

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule, addr image):
        dieTooManyArgs()
    else:
      dieInvalidOption p.key

  if capsule.isNone:
    dieCapsuleRequired()
  if image.isNone:
    die "An image is required."

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = false)
  suAction Action.SuCreate, @[capsuleInfo.name, image.get]

makeCommand(Action.SuCreate, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next
  var image = p.key

  discard existsOrCreateDir GlobalCapsulesPath

  if not fileExists EtcDefaultsJsonPath:
    die fmt"{EtcDefaultsJsonPath} must exist!"

  let defaultsJson = parseFile(EtcDefaultsJsonPath).to DefaultsJson

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = false)
  let capsuleJson = CapsuleJson(image: image, options: defaultsJson.options, persistence: @[])
  writeFileAtomic capsuleInfo.path, pretty %*capsuleJson

makeCommand(Action.Delete, "delete [-k|--keep-persistence]",
            "Delete the capsule (keep the persisted files if -k)") do (p: var OptParser):
  var capsule: Option[string]
  var keepPersistence = false

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule):
        dieTooManyArgs()
    else:
      case p.key
      of "k", "keep-persistence":
        keepPersistence = true
      else: dieInvalidOption p.key

  if capsule.isNone:
    dieCapsuleRequired()

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  suAction Action.SuDelete, @[capsuleInfo.name, $keepPersistence]

makeCommand(Action.SuDelete, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next
  var keepPersistence = parseBool p.key

  if keepPersistence:
    let persistence = getPersistenceRoot capsule
    removeDir persistence

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = true)
  removeFile capsuleInfo.path

makeCommand(Action.Trust, "trust [-u|--untrust]",
            "Trust the given capsule (use -u to untrust instead)") do (p: var OptParser):
  var capsule: Option[string]
  var untrust = false

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule):
        dieTooManyArgs()
    elsE:
      case p.key
      of "u", "untrust":
        untrust = true
      else: dieInvalidOption p.key

  if capsule.isNone:
    dieCapsuleRequired()

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  suAction Action.SuTrust, @[capsuleInfo.name, $untrust]

makeCommand(Action.SuTrust, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next
  var untrust = parseBool p.key
  discard resolveCapsuleInfo(capsule, shouldExist = true)

  var trustedJson: TrustedJson
  if fileExists GlobalPolkitTrustedPath:
    trustedJson = parseFile(GlobalPolkitTrustedPath).to TrustedJson

  trustedJson.trusted = mergeUnsorted(trustedJson.trusted, @[capsule], untrust)
  writeFileAtomic GlobalPolkitTrustedPath, pretty %*trustedJson

  # We use an object where trusted keys have a true value for the polkit JS.

  let trustedJsObjectNode = newJObject()
  for trustedCapsule in trustedJson.trusted:
    trustedJsObjectNode.add trustedCapsule, newJBool(true)

  let trustedJsString = pretty trustedJsObjectNode
  let rulesJs = RulesJs.replace("<TRUSTED>", trustedJsString).replace("<REGEX>", CapsuleRegex)
  writeFileAtomic PolkitRulesPath, rulesJs

makeCommand(Action.OptionsModify, "options-modify ... [-r|--remove] [OPTIONS...]",
            "Add options to a capsule (or remove them if -r is given)") do (p: var OptParser):
  var capsule: Option[string]
  var options: seq[string]
  var remove = false

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule):
        options.add p.key
    else:
      case p.key
      of "r", "remove":
        remove = true
      else: dieInvalidOption p.key

  if capsule.isNone:
    dieCapsuleRequired()
  elif options.len == 0:
    die "At least one option must be given."

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  var params = @[capsuleInfo.name, $remove]
  params.add options
  suAction Action.SuOptionsModify, params

makeCommand(Action.SuOptionsModify, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next
  var remove = parseBool p.key
  p.next

  var modOptions: seq[string]

  p.walkOpts:
    assert p.kind == cmdArgument
    modOptions.add p.key

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = true)
  var capsuleJson = parseFile(capsuleInfo.path).to CapsuleJson

  capsuleJson.options = mergeUnsorted(capsuleJson.options, modOptions, remove)
  writeFileAtomic capsuleInfo.path, pretty %*capsuleJson

makeCommand(Action.OptionsDump, "options-dump",
            "Dump the capsule's options") do (p: var OptParser):
  var capsule: Option[string]

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule):
        dieTooManyArgs()
    else:
      dieInvalidOption p.key

  if capsule.isNone:
    dieCapsuleRequired()

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  echo readFile capsuleInfo.path

makeCommand(Action.Persistence,
            "persistence ... [-r|--remove] [-k|--keep] DIRECTORY",
            "Add a persistent directory (if -r is given, remove instead, and if -k is given, " &
            "don't delete the persisted files)") do (p: var OptParser):
  var capsule: Option[string]
  var directory: Option[string]
  var remove = false
  var keepPersistence = false

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule, addr directory):
        dieTooManyArgs()
    else:
      case p.key
      of "r", "remove":
        remove = true
      of "k", "keep-persistence":
        keepPersistence = true
      else: dieInvalidOption(p.key)

  if capsule.isNone:
    dieCapsuleRequired()
  elif directory.isNone:
    die "A directory to persist is required"

  if keepPersistence and not remove:
    die "-k doesn't make sense without -r"

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  suAction Action.SuPersistence, @[capsuleInfo.name, absolutePath(directory.get), $remove,
                                   $keepPersistence]

makeCommand(Action.SuPersistence, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next
  var directory = p.key
  p.next
  var remove = parseBool p.key
  p.next
  var keepPersistence = parseBool p.key

  assert directory.isAbsolute

  let uid = getOriginalUid()
  let storage = getPersistenceRoot(capsule) / directory

  if not remove:
    discard existsOrCreateDirWithParents storage
    let rc = chown(storage, Uid(parseUInt(uid)), Gid(parseUInt(uid)))
    if rc == -1:
      die fmt"chown of {storage} failed: {strerror(errno)}"

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = true)
  var capsuleJson = parseFile(capsuleInfo.path).to CapsuleJson

  capsuleJson.persistence = mergeUnsorted(capsuleJson.persistence, @[directory], remove)
  writeFileAtomic capsuleInfo.path, pretty %*capsuleJson

  if remove and not keepPersistence:
    removeDir getPersistenceRoot(capsule) / directory

proc runCapsule(capsule, workdir: string, command: seq[string]) =
  checkUnderHome workdir, getOriginalHome()

  let capsuleInfo =
    # Directly run an image.
    if capsule.startsWith '@': CapsuleInfo(name: capsule, path: "")
    else: resolveCapsuleInfo(capsule, shouldExist = true)
  debug fmt"runCapsule: {capsuleInfo.name} in {workdir}: {quoteShellCommand(command)}"
  suAction Action.SuRun, @[capsuleInfo.name, workdir] & command

proc runExportedInternal() =
  let params = commandLineParams()
  var capsule = params[0]
  let file = params[1]

  capsule.removePrefix "run-exported-internal:"

  var command = @[sequtils.toSeq(readFile(file).splitLines)[1]]
  command.add params[2..^1]

  runCapsule capsule, getCurrentDir(), command

makeCommand(Action.Run, "run ... [-w|--workdir WORKDIR] [COMMAND...]",
            "Run a command within a capsule") do (p: var OptParser):
  var capsule: Option[string]
  var workdir = getCurrentDir()

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule):
        break
    else:
      case p.key
      of "w", "workdir":
        if p.val.len == 0:
          die "-w/--workdir requires an argument."
        if not dirExists p.val:
          die fmt"Non-existent working directory: {p.val}"
        workdir = expandFilename p.val
      else: dieInvalidOption(p.key)

  if capsule.isNone:
    dieCapsuleRequired()

  # HACK: to get the unadultered arguments, just go straight to commandLineParams
  # This and the below hack should be removed once a Nim comes out with
  # OptParser.remainingArgs (ref. https://github.com/nim-lang/Nim/issues/9951).

  # This hack influences several other parts of the code; for instance, suAction must
  # always use pkexec even if the user is already is already root.
  var
    params = commandLineParams()[0..^1]
    passedCapsule = false
  params[0..^1] = params[params.find("run")+1..^1]
  for i, param in params:
    if not param.startsWith('-'):
      if passedCapsule:
        params[0..^1] = params[i..^1]
        break
      else:
        passedCapsule = true

  if params.len == 0 or not passedCapsule:
    die "A command is required."

  runCapsule capsule.get, workdir, params

makeCommand(Action.SuRun, "", "") do (p: var OptParser):
  # HACK: see above comment in Action.Run's command
  var params = commandLineParams()[1..^1]
  if params[^1] == InternalVerboseArg:
    discard params.pop
  debug fmt"su-run: {params}"

  let capsule = params[0]
  let workdir = params[1]
  let command = params[2..^1]

  let persistenceRoot = getPersistenceRoot capsule

  let uniq = uniqueValue()
  let uid = getOriginalUid()
  let home = getOriginalHome()
  let workdirRelative = checkUnderHome(workdir, home)

  var args = @[
    "run", "--security-opt=label=disable", fmt"--volume={home}:/run/home",
    fmt"--name={capsule}-{uniq}", fmt"--workdir=/run/home/{workdirRelative}", "--rm",
    "--attach=stdin", "--attach=stdout", "--attach=stderr", "--tty",
    "--env=HOME=/var/data", "--tmpfs=/var/data", "--entrypoint=sh"
  ]

  if gVerbose:
    args.insert "--log-level=debug"

  if not gRootless:
    args.add fmt"--user={uid}"

  if capsule.startsWith '@':
    # Directly run an image.
    let defaultsJson = parseFile(EtcDefaultsJsonPath).to DefaultsJson

    args.add defaultsJson.options.mapIt(string, "--" & it)
    args.add capsule[1..^1]
  else:
    let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = true)
    let capsuleJson = parseFile(capsuleInfo.path).to CapsuleJson

    args.add capsuleJson.options.mapIt(string, "--" & it)
    args.add capsuleJson.persistence.mapIt(string, fmt"--volume={persistenceRoot / it}:{it}")

    args.add capsuleJson.image

  args.add @["-l", "-c", "exec \"$@\"", command[0]]
  args.add command

  replaceProcess("podman", args = args)

makeCommand(Action.Export, "export ... [--as=NAME] EXECUTABLE",
            "Export a command from the capsule") do (p: var OptParser):
  var capsule: Option[string]
  var executable: Option[string]
  var name: Option[string]

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule, addr executable):
        dieTooManyArgs()
    else:
      case p.key
      of "as":
        name = some p.val
      else: dieInvalidOption(p.key)

  if capsule.isNone:
    dieCapsuleRequired()
  elif executable.isNone:
    die "A command to run is required."

  if name.isNone:
    name = some executable.get.extractFilename

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  suAction Action.SuExport, @[capsuleInfo.name, name.get, executable.get]

makeCommand(Action.SuExport, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next
  var name = p.key
  p.next
  var command = p.key

  let path = GlobalExportsBinPath / name
  if fileExists path:
    die fmt"Export at {path} already exists (try passing --as with a different name)"

  writeFileAtomic path, fmt"#!{getAppFilename()} run-exported-internal:{capsule}" & "\n" &
                        command & "\n"
  setFilePermissions path, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead,
                            fpOthersExec, fpOthersRead}

makeCommand(Action.Link, "link ... [DIRECTORY]",
            "Link a capsule into the directory (cwd is the default)") do (p: var OptParser):
  var capsule: Option[string]
  var directory: Option[string]

  p.walkOpts:
    if p.kind == cmdArgument:
      if not assignToFirstNone(p.key, addr capsule, addr directory):
        dieTooManyArgs()
    else:
      dieInvalidOption p.key

  if capsule.isNone:
    dieCapsuleRequired()
  elif directory.isNone:
    directory = some getCurrentDir()

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)

  let target = directory.get / ".bluecap" / "default.json"
  discard existsOrCreateDirWithParents target.parentDir

  removeFile target
  createSymlink capsuleInfo.path, target

proc enableVerbose() =
  if gVerbose:
    return

  gVerbose = true
  addHandler newConsoleLogger()

proc enableRootless() =
  gRootless = true

proc main() =
  randomize()

  var action: Option[Action]

  var params = commandLineParams()
  if params.len != 0 and params[^1] == InternalVerboseArg:
    enableVerbose()
    discard params.pop
  elif getEnv("BLUECAP_VERBOSE").len != 0:
    enableVerbose()

  if getEnv("BLUECAP_ROOTLESS").len != 0:
    enableRootless()

  var p = initOptParser params
  p.next

  p.walkOpts:
    if p.kind == cmdArgument:
      if p.key.startsWith "run-exported-internal:":
        runExportedInternal()

      if p.key == "help":
        showHelp()

      if action.isNone:
        try:
          action = some parseDashEnum[Action](p.key)
        except InvalidEnumValue:
          die "Invalid command: " & p.key

        # We have the action, now we can pass the OptParser along to the command.
        p.next
        break
    else:
      case p.key
      of "help", "h", "?":
        showHelp()
      of "verbose", "v":
        enableVerbose()
      of "rootless", "r":
        enableRootless()
      else:
        dieInvalidOption p.key

  if action.isNone:
    die "A command is required."

  commands[action.get].call(p)

main()
