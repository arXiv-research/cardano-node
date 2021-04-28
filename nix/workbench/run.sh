global_runsdir_def=${global_runsdir:-$(realpath "$global_basedir/../../run")}
global_runsdir=$global_runsdir_def

usage_run() {
     usage "run" "Managing cluster runs" <<EOF

    list                  List cluster runs

    allocate BATCH-NAME PROFILE-NAME [ENV-CONFIG-OPTS..]
                          Allocate a cluster run with the specified:
                            - batch key (no semantics attached)
                            - profile name
                          A unique name would be allocated for this run,
                            and a run alias 'current' will be created for it.

    start NAME            Start the named run

  Options:

    --runsdir DIR         Set the runs directory.  Defaults to $global_runsdir_def
EOF
}

run() {
while test $# -gt 0
do case "$1" in
       --runsdir )
           global_runsdir=$2; shift;;
       * ) break;; esac; shift; done

local op=${1:-list}; test $# -gt 0 && shift

case "$op" in
    list )
        test -d "$global_runsdir" && cd "$global_runsdir" &&
            ls | {
                ## Filter out aliases:
                grep -v 'current' || true; }
        ;;

    show | s )
        local usage="USAGE: wb run $op RUN-NAME"
        local name=${1:?$usage}

        local dir=$global_runsdir/$name
        jq '.' "$dir"/meta.json
        ;;

    check )
        local usage="USAGE: wb run $op RUN-NAME"
        local name=${1:?$usage}
        local dir=$global_runsdir/$name

        for f in "$dir"/{profile,env,meta}.json
        do if ! jq_check_json "$f"
           then return 1
           fi
        done
        ;;

    set-current | set )
        local usage="USAGE: wb run $op RUN-NAME"
        local name=${1:?$usage}
        local dir=$global_runsdir/$name

        if ! run check "$name"
        then fatal "run fails sanity checks:  $name at $dir"; fi

        rm -f       "$global_runsdir"/current
        ln -s $name "$global_runsdir"/current

        msg "current run is:  $name at:  $dir"
        ;;

    current-run-path | current-path | path )
        realpath "$global_runsdir"/current;;

    current-run-name | current-name | name | current )
        basename "$(run current-path)";;

    current-run-meta | current-meta | meta )
        jq '.' "$(run current-path)"/meta.json;;

    current-run-profile | current-profile | profile | p )
        jq '.' "$(run current-path)"/profile.json;;

    allocate )
        local usage="USAGE: wb run $op BATCH-NAME PROFILE-NAME [ENV-CONFIG-OPTS..] [-- BACKEND-ENV-CONFIG-OPTS..]"
        local batch=${1:?$usage}
        local prof=${2:?$usage}

        local cacheDir=$default_cacheDir basePort=$default_basePort staggerPorts='false' got_backend_opts=
        while test $# -gt 0
        do case "$1" in
               --cache-dir )     cacheDir=$2; shift;;
               --base-port )     basePort=$2; shift;;
               --stagger-ports ) staggerPorts=true; shift;;
               # -- )              got_backend_opts=true; break;;
               --* ) msg "FATAL:  unknown flag '$1'"; usage_run;;
               * ) break;; esac; shift; done

        local epoch=$(date +'%s' --utc)
        local time=$(date +'%Y'-'%m'-'%d'-'%H.%M' --date=@$epoch --utc)
        local name=$time.$batch.$prof
        local dir=$global_runsdir/$name
        local realdir=$(realpath --canonicalize-missing "$dir")

        if test "$(dirname "$realdir")" != "$(realpath "$global_runsdir")"
        then fatal "bad run name/run dir:  $name @ $dir"; fi

        if test -e "$dir"
        then fatal "run name busy:  $name @ $dir"; fi

        if ! profile has-profile          "$prof"
        then fatal      "no such profile:  $prof"; fi

        mkdir -p "$cacheDir" && test -w "$global_cachedir" ||
            fatal "failed to create writable cache directory:  $global_cachedir"

        mkdir -p "$dir" && test -w "$dir" ||
            fatal "failed to create writable run directory:  $dir"

        local env_json="$dir"/env.json
        local args=(
            --arg     cacheDir    "$cacheDir"
            --argjson basePort     $basePort
            --argjson staggerPorts $staggerPorts
        )
        jq_fmutate "$env_json" '
          { cacheDir:     $cacheDir
          , basePort:     $basePort
          , staggerPorts: $staggerPorts
          }
        ' "${args[@]}"

        if test -n "$got_backend_opts"
        then backend record-extended-env-config "$env_json" "$@"; fi

        profile get "$prof" > "$dir"/profile.json
        profile node-specs    "$dir"/profile.json "$dir"/env.json > "$dir"/node-specs.json

        local args=(
            --arg name      $name
            --arg batch     $batch
            --arg prof      $prof
            --arg epoch     $epoch
            --arg time      $time
        )
        jq_fmutate "$dir"/meta.json '. *
           { name:      $name
           , batch:     $batch
           , profile:   $prof
           , epoch:     $epoch
           , time:      $time
           }
           ' "${args[@]}"

        topology make    "$dir"/profile.json "$dir"/topology

        for node in $(jq_tolist 'keys' "$dir"/node-specs.json)
        do local node_dir="$dir"/$node
           mkdir -p                           "$node_dir"
           jq .$node "$dir"/node-specs.json > "$node_dir"/node-spec.json
        done

        run     describe "$dir"
        profile describe "$dir"/profile.json
        ;;

    describe )
        local usage="USAGE: wb run $op RUN-NAME"
        local name=${1:?$usage}
        local dir=$global_runsdir/$name

        if ! run check "$name"
        then fatal "run fails sanity checks:  $name at $dir"; fi

        cat <<EOF
workbench:  run $name params:
  - run dir:         $dir
  - profile JSON:    $dir/profile.json
  - node specs:      $dir/node-specs.json
  - topology:        $dir/topology/topology-nixops.json $dir/topology/topology.pdf
  - node base port:  $(jq .basePort "$dir"/env.json)
EOF
        backend describe-run "$dir"
        ;;

    start )
        local usage="USAGE: wb run $op RUN-NAME"
        local name=${1:-?$usage}

        run set-current "$name"
        local currentRunPath=$(run current-path)
        local cacheDir=$(jq .cacheDir "$currentRunPath"/meta.json)

        local genesis_args+=(
            ## Positionals:
            "$cacheDir"/genesis
            "$currentRunPath"/profile.json
            "$currentRunPath"/topology
            "$currentRunPath"/genesis
        )
        genesis prepare "''${genesis_args[@]}"
        ;;

    * ) usage_run;; esac
}
