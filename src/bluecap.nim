# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# NOTE: If you're wondering about all the var xyz = p.key:
# https://github.com/nim-lang/Nim/issues/2314


import
  json,
  nre,
  os,
  ospaths,
  osproc,
  options,
  parseopt,
  posix,
  sets,
  sequtils,
  streams,
  strformat,
  strutils,
  tables,
  terminal,
  typetraits,
  uuids


const CapsuleRegex = r"^[0-9a-zA-Z_.\-]+$"

const PolkitRulesPath = "/etc/polkit-1/rules.d/49-bluecap.rules"
const EtcStoragePath = "/etc/bluecap"
const EtcDefaultsJsonPath = EtcStoragePath / "defaults.json"
const GlobalStoragePath = "/var/lib/bluecap"
const GlobalCapsulesPath = GlobalStoragePath / "capsules"
const GlobalExportsPath = GlobalStoragePath / "exports"
const GlobalExportsBinPath = GlobalExportsPath / "bin"
const GlobalPersistencePath = GlobalStoragePath / "persistence"
const GlobalPolkitTrustedPath = GlobalStoragePath / "polkit-trusted.json"

const RulesJs = """// THIS FILE IS AUTOMATICALLY GENERATED by bluecap
// Do NOT edit: your changes will be overwritten!

var TRUSTED = <TRUSTED>

polkit.addRule(function (action, subject) {
    if (action.id == 'com.refi64.Bluecap.run') {
        var cmdline = action.lookup('command_line')
        var capsule = cmdline.match(/internal-run (\S+)/)[1]
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
    Create, Delete, Trust, OptionsModify, OptionsDump, Persistence, Run, Export,
    SuCreate, SuDelete, SuTrust, SuOptionsModify, SuPersistence, SuRun, SuExport, Link

  AvailableCapsuleInfo = object
    name: string
    path: string

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


proc die(s: string) =
  stderr.writeLine s
  quit 1

proc dieCapsuleRequired() = die "A capsule is required."
proc dieInvalidOption(arg: string) = die "Invalid option: " & arg
proc dieTooManyArgs() = die "Too many arguments."


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
  discard execvp(command, allocCStringArray(args2))
  die fmt"execvp failed: {strerror(errno)}"

proc getOriginalUid(): string =
  result = getEnv "PKEXEC_UID"
  if result.len == 0:
    result = getEnv "SUDO_UID"
  if result.len == 0:
    result = $getuid()

proc getOriginalHome(): string =
  let uid = Uid(parseUInt(getOriginalUid()))
  if uid == getuid():
    return getHomeDir()

  let passwd = getpwuid uid
  return $passwd.pw_dir

proc removePathPrefix(path, prefix: string): string =
  assert path.startsWith prefix
  result = path
  removePrefix result, prefix
  removePrefix result, '/'

proc checkUnderHome(dir, home: string): string {.discardable.} =
  var resolvedHome = expandFilename home
  if not dir.startsWith resolvedHome:
    die "Current directory is not under your home directory."

  return removePathPrefix(dir, resolvedHome)

proc resolveCapsuleInfo(name: string, shouldExist: bool): AvailableCapsuleInfo =
  if name == ".":
    for parent in parentDirs getCurrentDir():
      let default = parent / ".bluecap" / "default.json"
      if existsFile default:
        result.path = expandSymlink default
        result.name = splitFile(result.path)[1]
        break

    if result.name.len == 0:
      die "No capsule has been linked."
  else:
    result.name = name
    result.path = (GlobalCapsulesPath / name) & ".json"

  if not result.name.contains re(CapsuleRegex):
    die fmt"Invalid capsule name: {result.name}"

  if shouldExist and not existsFile result.path:
    die fmt"Capsule {name} does not exist."
  elif not shouldExist and existsFile result.path:
    die fmt"Capsule {name} already exists."

proc getPersistenceRoot(capsule: string): string =
  return GlobalPersistencePath / capsule

var commands = initOrderedTable[Action, Command]()

proc showHelp() =
  echo "bluecap [-? | -h | --help] COMMAND CAPSULE [ARGS...]"
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
  let command = Command(synop: synop, help: help, call: call)
  commands[action] = Command(synop: synop, help: help, call: call)

proc suAction(action: Action, args: openarray[string]) =
  if getuid() == 0:
    var p = initOptParser quoteShellCommand(args)
    p.next()
    commands[action].call p
    quit()
  else:
    var pkArgs = newSeqOfCap[string] args.len + 2
    pkArgs.add getAppFilename()
    pkArgs.add camelToDash($action)
    pkArgs.add args

    replaceProcess("pkexec", args = pkArgs)

makeCommand(Action.Create, "create ... IMAGE",
            "Create a capsule from the given image") do (p: var OptParser):
  var capsule: Option[string]
  var image: Option[string]

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      elif image.isNone:
        image = some p.key
      else:
        dieTooManyArgs()
    of cmdLongOption, cmdShortOption: dieInvalidOption p.key
    of cmdEnd: assert false

    p.next()

  if capsule.isNone:
    dieCapsuleRequired()
  if image.isNone:
    die "An image is required."

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = false)
  suAction Action.SuCreate, @[capsuleInfo.name, image.get]

makeCommand(Action.SuCreate, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next()
  var image = p.key

  discard existsOrCreateDir GlobalCapsulesPath

  if not existsFile EtcDefaultsJsonPath:
    die fmt"{EtcDefaultsJsonPath} must exist!"

  let defaultsJson = parseFile(EtcDefaultsJsonPath).to DefaultsJson

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = false)
  let capsuleJson = CapsuleJson(image: image, options: defaultsJson.options, persistence: @[])
  writeFileAtomic capsuleInfo.path, pretty %*capsuleJson

makeCommand(Action.Delete, "delete [-k|--keep-persistence]",
            "Delete the capsule (keep the persisted files if -k)") do (p: var OptParser):
  var capsule: Option[string]
  var keepPersistence = false

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      else:
        dieTooManyArgs()
    of cmdLongOption, cmdShortOption:
      case p.key
      of "k", "keep-persistence":
        keepPersistence = true
      else: dieInvalidOption p.key
    of cmdEnd: assert false

    p.next()

  if capsule.isNone:
    dieCapsuleRequired()

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  suAction Action.SuDelete, @[capsuleInfo.name, $keepPersistence]

makeCommand(Action.SuDelete, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next()
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

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      else:
        dieTooManyArgs()
    of cmdLongOption, cmdShortOption:
      case p.key
      of "u", "untrust":
        untrust = true
      else: dieInvalidOption p.key
    of cmdEnd: assert false

    p.next()

  if capsule.isNone:
    dieCapsuleRequired()

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  suAction Action.SuTrust, @[capsuleInfo.name, $untrust]

makeCommand(Action.SuTrust, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next()
  var untrust = parseBool p.key
  discard resolveCapsuleInfo(capsule, shouldExist = true)

  var trusted = initSet[string]()

  var trustedJson: TrustedJson
  if existsFile GlobalPolkitTrustedPath:
    trustedJson = parseFile(GlobalPolkitTrustedPath).to TrustedJson

  trustedJson.trusted = mergeUnsorted(trustedJson.trusted, @[capsule], untrust)
  writeFileAtomic GlobalPolkitTrustedPath, pretty %*trustedJson

  # We use an object where trusted keys have a true value for the polkit JS.

  let trustedJsObjectNode = newJObject()
  for trustedCapsule in trusted.items:
    trustedJsObjectNode.add trustedCapsule, newJBool(true)

  let trustedJsString = pretty trustedJsObjectNode
  let rulesJs = RulesJs.replace("<TRUSTED>", trustedJsString).replace("<REGEX>", CapsuleRegex)
  writeFileAtomic PolkitRulesPath, rulesJs

makeCommand(Action.OptionsModify, "options-modify ... [-r|--remove] [OPTIONS...]",
            "Add options to a capsule (or remove them if -r is given)") do (p: var OptParser):
  var capsule: Option[string]
  var options: seq[string]
  var remove = false

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      else:
        options.add p.key
    of cmdLongOption, cmdShortOption:
      case p.key
      of "r", "remove":
        remove = true
      else: dieInvalidOption p.key
    of cmdEnd: assert false

    p.next()

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
  p.next()
  var remove = parseBool p.key
  p.next()

  var modOptions: seq[string]

  while p.kind != cmdEnd:
    assert p.kind == cmdArgument
    modOptions.add p.key
    p.next()

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = true)
  var capsuleJson = parseFile(capsuleInfo.path).to CapsuleJson

  capsuleJson.options = mergeUnsorted(capsuleJson.options, modOptions, remove)
  writeFileAtomic capsuleInfo.path, pretty %*capsuleJson

makeCommand(Action.OptionsDump, "options-dump",
            "Dump the capsule's options") do (p: var OptParser):
  var capsule: Option[string]

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      else:
        dieTooManyArgs()
    of cmdLongOption, cmdShortOption: dieInvalidOption p.key
    of cmdEnd: assert false

    p.next()

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

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      elif directory.isNone:
        directory = some p.key
      else:
        dieTooManyArgs()
    of cmdLongOption, cmdShortOption:
      case p.key
      of "r", "remove":
        remove = true
      of "k", "keep-persistence":
        keepPersistence = true
      else: dieInvalidOption(p.key)
    of cmdEnd: assert false

    p.next()

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
  p.next()
  var directory = p.key
  p.next()
  var remove = parseBool p.key
  p.next()
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

proc runCapsule(capsule, command: string) =
  let cwd = getCurrentDir()
  checkUnderHome cwd, getOriginalHome()

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = true)
  suAction Action.SuRun, @[capsuleInfo.name, cwd, command]

proc runExportedInternal() =
  let params = commandLineParams()
  var capsule = params[0]
  let file = params[1]

  capsule.removePrefix "run-exported-internal:"

  var commandSeq = parseCmdLine(sequtils.toSeq(readFile(file).splitLines)[1])
  commandSeq.add params[2..^1]

  runCapsule capsule, quoteShellCommand(commandSeq)

makeCommand(Action.Run, "run ... [COMMAND...]",
            "Run a command within a capsule") do (p: var OptParser):
  # HACK: to get the unadultered arguments, just go straight to commandLineParams
  var params = commandLineParams()[1..^1]
  if params.len == 0:
    dieCapsuleRequired()
  elif params.len == 1:
    die "A command is required."

  runCapsule params[0], quoteShellCommand(params[1..^1])

makeCommand(Action.SuRun, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next()
  var cwd = p.key
  p.next()
  var command = p.key

  let capsuleInfo = resolveCapsuleInfo(capsule, shouldExist = true)
  let capsuleJson = parseFile(capsuleInfo.path).to CapsuleJson

  let persistenceRoot = getPersistenceRoot capsule

  let uuid = ($genUUID())[0..7]
  let uid = getOriginalUid()
  let home = getOriginalHome()
  let cwdRelative = checkUnderHome(cwd, home)

  var podman = @[
    "podman", "run", "--security-opt=label=disable", fmt"--volume={home}:/run/home",
    fmt"--name={capsule}-{uuid}", fmt"--workdir=/run/home/{cwdRelative}", "--rm",
    "--attach=stdin", "--attach=stdout", "--attach=stderr", "--tty",
    fmt"--user={uid}", "--env=HOME=/var/data", "--tmpfs=/var/data"
  ]

  podman.add capsuleJson.options.mapIt(string, "--" & it)
  podman.add capsuleJson.persistence.mapIt(string, fmt"--volume={persistenceRoot / it}:{it}")

  podman.add capsuleJson.image
  podman.add parseCmdLine(command)

  echo quoteShellCommand(podman)
  discard execvp("podman", allocCStringArray(podman))
  die fmt"execvp failed: {strerror(errno)}"

makeCommand(Action.Export, "export ... [--as=NAME] COMMAND...",
            "Export a command from the capsule") do (p: var OptParser):
  var capsule: Option[string]
  var command: seq[string]
  var name: Option[string]

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      else:
        command.add p.key
    of cmdLongOption, cmdShortOption:
      case p.key
      of "as":
        name = some p.val
      else: dieInvalidOption(p.key)
    of cmdEnd: assert false

    p.next()

  if capsule.isNone:
    dieCapsuleRequired()
  if command.len == 0:
    die "A command is required."

  if name.isNone:
    name = some command[0]

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)
  suAction Action.SuExport, @[capsuleInfo.name, name.get, quoteShellCommand(command)]

makeCommand(Action.SuExport, "", "") do (p: var OptParser):
  var capsule = p.key
  p.next()
  var name = p.key
  p.next()
  var command = p.key

  let path = GlobalExportsBinPath / name
  if existsFile path:
    die fmt"Export at {path} already exists (try passing --as with a different name)"

  writeFileAtomic path, fmt"#!{getAppFilename()} run-exported-internal:{capsule}" & "\n" &
                        command & "\n"
  setFilePermissions path, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead,
                            fpOthersExec, fpOthersRead}

makeCommand(Action.Link, "link ... [DIRECTORY]",
            "Link a capsule into the directory (cwd is the default)") do (p: var OptParser):
  var capsule: Option[string]
  var directory: Option[string]

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
      if capsule.isNone:
        capsule = some p.key
      elif directory.isNone:
        directory = some p.key
      else:
        dieTooManyArgs()
    of cmdLongOption, cmdShortOption:
      dieInvalidOption p.key
    of cmdEnd: assert false

    p.next()

  if capsule.isNone:
    dieCapsuleRequired()
  elif directory.isNone:
    directory = some getCurrentDir()

  let capsuleInfo = resolveCapsuleInfo(capsule.get, shouldExist = true)

  let target = directory.get / ".bluecap" / "default.json"
  discard existsOrCreateDirWithParents target.parentDir

  removeFile target
  createSymlink capsuleInfo.path, target

proc main() =
  var action: Option[Action]
  var p = initOptParser()

  p.next()

  while p.kind != cmdEnd:
    case p.kind
    of cmdArgument:
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
        p.next()
        break
    of cmdLongOption, cmdShortOption:
      case p.key
      of "help", "h", "?":
        showHelp()
      else:
        dieInvalidOption p.key
    of cmdEnd: assert false

    p.next()

  if action.isNone:
    die "A command is required."

  commands[action.get].call(p)

main()