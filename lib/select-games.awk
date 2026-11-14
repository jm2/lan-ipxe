# select-games.awk - choose what the `games` profile installs from the LAN
# game-packages repository. Shared by setup-arch-workstation.sh and
# setup-fedora-workstation.sh; setup-win11-workstation.ps1 carries the same
# rules in Select-GamePackage. POSIX awk (mawk on Ubuntu CI, gawk on Arch and
# Fedora).
#
# Input, tab-separated; list fields are space-separated bare names (version
# constraints and rich dependencies already stripped by the caller):
#   R <name> <installed size in bytes> <provides> <conflicts> <depends>
#       a package the repository publishes (one record per name)
#   I <name> <provides> <conflicts>
#       an installed package, from any repository
# Variables:
#   exclude  ERE matching whole names that are not games (tools, servers,
#            libraries and runtimes; the games pull in what they need)
#   avail    free bytes on the filesystem the games install to (/opt)
#   total    size in bytes of that filesystem
#   reserve  percent of total that must stay free once everything installed
#
# Rules:
#   - Everything the repository publishes except `exclude` is a candidate.
#   - Installed candidates are kept, so earlier choices win.
#   - Alternatives of one game (declared conflicts or provides, or names
#     that differ only in a trailing -gog/-steam/-archiveorg/-revoltio/-hib
#     source) resolve to GOG first, then Steam, then any other source.
#   - A candidate conflicting with any installed package is skipped.
#   - A candidate needing something that only a skipped candidate provides
#     is skipped too (a GOG DLC once the GOG game lost, an engine whose
#     data package was dropped), so no unwanted alternative is pulled in.
#   - When the new packages would leave less than `reserve` percent free,
#     the largest are dropped until they fit (a ballpark: dependencies from
#     the distribution and download caches are not counted).
#
# Output, one line each, installs in dependency order (providers first):
#   keep <name>
#   install <name> <size> [<new package it depends on>...]
#   skip <name> <reason>
#   space <bytes needed> <avail> <total> <bytes kept free>

BEGIN { FS = "\t"; nr = 0; ni = 0 }

$1 == "R" {
  if ($2 in rsize) next
  rname[++nr] = $2
  rsize[$2] = $3 + 0
  rprov[$2] = $2 " " $4
  rconf[$2] = $5
  rdep[$2] = $6
  next
}

$1 == "I" {
  iname[++ni] = $2
  inst[$2] = 1
  iprov[$2] = $2 " " $3
  iconf[$2] = $4
  next
}

function has(list, word,   parts, k, m) {
  m = split(list, parts, " ")
  for (k = 1; k <= m; k++) if (parts[k] == word) return 1
  return 0
}

function overlap(a, b,   parts, k, m) {
  m = split(a, parts, " ")
  for (k = 1; k <= m; k++) if (parts[k] != "" && has(b, parts[k])) return 1
  return 0
}

function source_rank(n) {
  if (n ~ /(^|-)gog(-|$)/) return 0
  if (n ~ /(^|-)steam(-|$)/) return 1
  return 2
}

function game_key(n,   k) {
  k = n
  sub(/-(gog|steam|archiveorg|revoltio|hib)$/, "", k)
  return k
}

# alternatives: the same game from two sources, or a declared conflict.
function alternatives(a, b) {
  if (game_key(a) != a && game_key(a) == game_key(b)) return 1
  return overlap(rconf[a], rprov[b]) || overlap(rconf[b], rprov[a])
}

function before(a, b) {
  if (source_rank(a) != source_rank(b)) return source_rank(a) < source_rank(b)
  return a < b
}

function provided(d,   n) {
  for (n in chosen) if (has(rprov[n], d)) return 1
  for (n in inst) if (has(iprov[n], d)) return 1
  return 0
}

function candidate_provides(d,   n) {
  for (n in cand) if (has(rprov[n], d)) return 1
  return 0
}

# Drops chosen packages whose dependencies only a skipped candidate provides,
# until nothing changes.
function close_deps(   changed, n, deps, k, m) {
  do {
    changed = 0
    for (n in fresh) {
      m = split(rdep[n], deps, " ")
      for (k = 1; k <= m; k++) {
        if (deps[k] == "" || provided(deps[k]) || !candidate_provides(deps[k])) continue
        reason[n] = "needs " deps[k] ", which is not selected"
        delete fresh[n]; delete chosen[n]; changed = 1
        break
      }
    }
  } while (changed)
}

# providers <name>: " <provider>..." for the new packages that satisfy its
# dependencies, so the caller can skip it when one of them failed instead of
# letting the package manager substitute another alternative.
function providers(n,   deps, k, m, o, out) {
  out = ""
  m = split(rdep[n], deps, " ")
  for (k = 1; k <= m; k++)
    for (o in fresh) if (o != n && has(rprov[o], deps[k]) && !has(out, o)) out = out " " o
  return out
}

function need_bytes(   n, sum) {
  sum = 0
  for (n in fresh) sum += rsize[n]
  return sum
}

END {
  for (i = 1; i <= nr; i++) {
    n = rname[i]
    if (exclude != "" && n ~ ("^(" exclude ")$")) continue
    cand[n] = 1
    if (n in inst) chosen[n] = 1
  }

  # Candidates still to install, best source first (insertion sort: POSIX awk
  # has no sort, and the repository holds a few hundred packages at most).
  m = 0
  for (i = 1; i <= nr; i++) {
    n = rname[i]
    if (!(n in cand) || (n in inst)) continue
    j = ++m
    while (j > 1 && before(n, order[j - 1])) { order[j] = order[j - 1]; j-- }
    order[j] = n
  }

  for (i = 1; i <= m; i++) {
    n = order[i]
    why = ""
    for (j = 1; j <= ni && why == ""; j++) {
      o = iname[j]
      if (overlap(rconf[n], iprov[o]) || overlap(iconf[o], rprov[n])) why = "conflicts with installed " o
    }
    for (o in chosen) {
      if (why != "") break
      if (alternatives(n, o)) why = "alternative to " o
    }
    if (why != "") { reason[n] = why; continue }
    chosen[n] = 1
    fresh[n] = 1
  }
  close_deps()

  reserve_bytes = total * reserve / 100
  while (avail - need_bytes() < reserve_bytes) {
    big = ""
    for (n in fresh) if (big == "" || rsize[n] > rsize[big]) big = n
    if (big == "") break
    reason[big] = "would leave less than " reserve "% of the disk free"
    delete fresh[big]; delete chosen[big]
    close_deps()
  }

  for (i = 1; i <= nr; i++) if ((rname[i] in cand) && (rname[i] in inst)) print "keep " rname[i]

  # Providers first: emit a package once every chosen package it depends on
  # has been emitted (cycles, if any, fall through in source order).
  left = 0
  for (n in fresh) left++
  while (left > 0) {
    progress = 0
    for (i = 1; i <= m; i++) {
      n = order[i]
      if (!(n in fresh) || (n in done)) continue
      ready = 1
      k = split(rdep[n], deps, " ")
      for (j = 1; j <= k && ready; j++) {
        for (o in fresh) if (o != n && !(o in done) && has(rprov[o], deps[j])) { ready = 0; break }
      }
      if (!ready) continue
      print "install " n " " rsize[n] providers(n)
      done[n] = 1; left--; progress = 1
    }
    if (!progress) {
      for (i = 1; i <= m; i++) {
        n = order[i]
        if ((n in fresh) && !(n in done)) { print "install " n " " rsize[n] providers(n); done[n] = 1; left-- }
      }
    }
  }

  for (i = 1; i <= m; i++) if (order[i] in reason) print "skip " order[i] " " reason[order[i]]
  printf "space %.0f %.0f %.0f %.0f\n", need_bytes(), avail, total, reserve_bytes
}
