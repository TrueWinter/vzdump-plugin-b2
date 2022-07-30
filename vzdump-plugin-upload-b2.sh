#!/bin/bash
CONFIG_FILE=$(dirname $0)/upload-b2.config

. "$CONFIG_FILE"

if [ ! -r "$CONFIG_FILE" ] ; then
  echo "Where is my config file? Looked in $CONFIG_FILE."
  echo "If you have none, copy the template and enter your information."
  echo "If it is somewhere else, change the second line of this script."
  exit 1
fi
if [ ! -x "$GPG_BINARY" ] || [ ! -x "$B2_BINARY" ] || [ ! -x "$JQ_BINARY" ] || [ ! -r "$GPG_PASSPHRASE_FILE" ] ; then
  echo "Missing one of $GPG_BINARY, $B2_BINARY, $JQ_BINARY or $GPG_PASSPHRASE_FILE."
  echo "Or one of the binaries is not executable."
  exit 2
fi

# Eliminate duplicate slashes. B2 does not accept those in file paths.
TARFILE=$(sed 's#//#/#g' <<< "$TARFILE")
TARBASENAME=$(basename "$TARFILE")
VMID=$3
SECONDARY=${SECONDARY_STORAGE:-`pwd`}


if [ ! -d "$SECONDARY" ] ; then
  echo "Missing secondary storage path $SECONDARY. Got >$SECONDARY_STORAGE< from config file."
  exit 12
fi

if [ "$1" == "backup-end" ]; then
  # PVE v7 support
  if [[  -z "$TARFILE" ]] ; then
        TARFILE="$TARGET"
  fi

  echo "Backing up $VMTYPE $3"

  if [[  -z "$TARFILE" ]] ; then
    echo "Where is my tarfile?"
    exit 3
  fi

  echo "CHECKSUMMING whole tar."
  sha1sum -b "$TARFILE" >> "$TARFILE.sha1sums"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong checksumming."
    exit 4
  fi

  echo "SPLITTING into chunks sized <=$B2_SPLITSIZE_BYTE byte"
  cd "$DUMPDIR"
  time split --bytes=$B2_SPLITSIZE_BYTE --suffix-length=3 --numeric-suffixes "$TARBASENAME" "$SECONDARY/$TARBASENAME.split."
  if [ $? -ne 0 ] ; then
    echo "Something went wrong splitting."
    exit 5
  fi

  echo "CHECKSUMMING splits"
  cd "$SECONDARY"
  sha1sum -b $TARBASENAME.split.* >> "$DUMPDIR/$TARBASENAME.sha1sums"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong checksumming."
    exit 6
  fi

  echo "Deleting whole file"
  rm "$TARFILE"

  echo "ENCRYPTING"
  cd "$SECONDARY"
  ls -1 $TARBASENAME.split.* | time xargs --verbose -I % -n 1 -P $NUM_PARALLEL_GPG $GPG_BINARY --batch --no-tty --compress-level 0 --passphrase-file $GPG_PASSPHRASE_FILE -c --output "$DUMPDIR/%.gpg" "%"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong encrypting."
    exit 7
  fi

  echo "Checksumming encrypted splits"
  cd "$DUMPDIR"
  sha1sum -b $TARBASENAME.split.*.gpg >> "$TARBASENAME.sha1sums"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong checksumming."
    exit 8
  fi

  echo "Deleting cleartext splits"
  rm $SECONDARY/$TARBASENAME.split.???

  echo "AUTHORIZING AGAINST B2"
  $B2_BINARY authorize_account $B2_ACCOUNT_ID $B2_APPLICATION_KEY
  if [ $? -ne 0 ] ; then
    echo "Something went wrong authorizing."
    exit 9
  fi

  echo "UPLOADING to B2 with up to $NUM_PARALLEL_UPLOADS parallel uploads."
  ls -1 $TARFILE.sha1sums $TARFILE.split.* | xargs --verbose -I % -n 1 -P $NUM_PARALLEL_UPLOADS $B2_BINARY upload_file $B2_BUCKET "%" "$B2_PATH%"
  if [ $? -ne 0 ] ; then
    echo "Something went wrong uploading."
    exit 10
  fi

  echo "REMOVING older remote backups."
  # Base64 to avoid issues with spaces
  # https://www.starkandwayne.com/blog/bash-for-loop-over-json-array-using-jq/
  ALLFILES=$(b2 ls "$B2_BUCKET" "$B2_PATH" --recursive --json | jq -r '.[] | @base64')
  FILESARR=()
  TODELETEARR=()

  # Looping multiple times is not great, but I'm not that good at Bash
  for FILEJSON in $ALLFILES; do
    TMPVARFN=`echo $FILEJSON | base64 --decode | jq -r '.fileName'`

    if [[ $TMPVARFN =~ vzdump-.+-$VMID ]]; then
      FILESARR+=( $FILEJSON )
      if [[ ! $TMPVARFN =~ "$TARBASENAME" ]]; then
        TODELETEARR+=( $FILEJSON )
      fi
    fi
  done

  echo "${#FILESARR[@]} files from backups with VMID $VMID:"
  for FILESARRFILE in ${FILESARR[@]}; do
    echo $FILESARRFILE | base64 --decode | jq -r '.fileName'
  done

  echo "${#TODELETEARR[@]} files from backups with VMID $VMID but not from current backup $TARBASENAME:"
  for TODELETEFILE in ${TODELETEARR[@]}; do
    echo $TODELETEFILE | base64 --decode | jq -r '.fileName'
  done
  echo "Will delete ${#TODELETEARR[@]} files from older backups."

  for O in ${TODELETEARR[@]}; do
    TODELFILENAME=`echo $O | base64 --decode | jq -r '.fileName'`
    TODELFILEID=`echo $O | base64 --decode | jq -r '.fileId'`
    echo "Deleting $TODELFILENAME ($TODELFILEID)"
    $B2_BINARY delete_file_version $TODELFILENAME $TODELFILEID
    if [ $? -ne 0 ] ; then
      echo "Something went wrong deleting old remote backups."
      exit 11
    fi
  done

  echo "DELETING local encrypted splits"
  rm $TARFILE.split.*.gpg
fi
