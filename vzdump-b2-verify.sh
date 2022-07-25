#!/bin/bash
CONFIG_FILE=$(dirname $0)/upload-b2.config

. "$CONFIG_FILE"

if [ ! -r "$CONFIG_FILE" ] ; then
  echo "Where is my config file? Looked in $CONFIG_FILE."
  echo "If you have none, copy the template and enter your information."
  echo "If it is somewhere else, change the second line of this script."
  exit 1
fi
if [ ! -x "$GPG_BINARY" ] || [ ! -x "$B2_BINARY" ] || [ ! -x "$JQ_BINARY" ] || [ ! -x "$BASENAME_BINARY" ] || [ ! -r "$GPG_PASSPHRASE_FILE" ] ; then
  echo "Missing one of $GPG_BINARY, $B2_BINARY, $JQ_BINARY, $BASENAME_BINARY or $GPG_PASSPHRASE_FILE."
  echo "Or one of the binaries is not executable."
  exit 2
fi

if [ $# -lt 3 ] ; then
  echo "Please call me with three parameters."
  echo "a) The directory inside the bucket, e.g. 'hostname/rpool/backup/dump',"
  echo "b) The name of the (compressed) vma-file, e.g. 'vzdump-qemu-100-2016_02_11-12_15_02' and"
  echo "c) a directory where I can work. This directory must be empty."
  echo "vzdump-b2-verify.sh hostname/rpool/backup/dump vzdump-qemu-100-2016_02_11-12_15_02 /rpool/backup/restoretest"
  exit 3
fi

B2_PATH=$1
FILENAME=$2
DIR=$3

if [ ! -d "$DIR" ] ; then
  echo "Can't find $DIR or it is not a directory. Please create it."
  exit 4
fi

if [ ! -z "$(ls -A $DIR)" ]; then
  echo "$DIR must be empty."
  exit 4
fi

echo "AUTHORIZING AGAINST B2"
$B2_BINARY authorize_account $B2_ACCOUNT_ID $B2_APPLICATION_KEY
if [ $? -ne 0 ] ; then
  echo "Something went wrong authorizing."
  exit 5
fi

echo "LISTING ALL THE FILES"
B2_FILENAMES=$($B2_BINARY ls $B2_BUCKET "$B2_PATH")
B2_FILTERED=()

for B2_FILE_TMP in $B2_FILENAMES; do
  if [[ $B2_FILE_TMP =~ "$FILENAME" ]]; then
    B2_FILTERED+=( $B2_FILE_TMP )
  fi
done

if [ -z "$B2_FILTERED" ] ; then
  echo "No files after filtering. Result from B2 was:\n$B2_FILENAMES"
  exit 6
fi

echo "DOWNLOADING ALL THE FILES"
for B2_DL_FILE in ${B2_FILTERED[@]}; do
  B2_DL_FILE_NAME=`$BASENAME_BINARY $B2_DL_FILE`
  $B2_BINARY download-file-by-name $B2_BUCKET $B2_DL_FILE $DIR/$B2_DL_FILE_NAME
  if [ $? -ne 0 ] ; then
    echo "Something went wrong downloading the files."
    exit 6
  fi
done

SHA="$DIR/$FILENAME.*.sha1sums"
echo "CHECKING encrypted split sums"
sed -r "s/ .*\/(.+)/  \1/g" < $SHA | grep "gpg$" | bash -c "cd $DIR;sha1sum -c -"
if [ $? -ne 0 ] ; then
  echo "Encrypted split sums did not successfully verify."
  exit 7
fi

echo "OK: encrypted split sums"

echo "DECRYPTING"
FILES_TO_DECRYPT=`ls -1 "$DIR/" | grep "$FILENAME" | grep ".gpg"`
for FILE_TO_DECRYPT in $FILES_TO_DECRYPT; do
  FILE_TO_DECRYPT_OUT=`echo $FILE_TO_DECRYPT | sed 's/\.gpg$//g'`
  $GPG_BINARY --batch --decrypt --output "$DIR/$FILE_TO_DECRYPT_OUT" --passphrase-file $GPG_PASSPHRASE_FILE "$DIR/$FILE_TO_DECRYPT"
  if [ $? -ne 0 ] ; then
    echo "Decrypting failed."
    exit 8
  fi
done

echo "CHECKING decrypted split sums"
sed -r "s/ .*\/(.+)/  \1/g" < $SHA | egrep ".split.[0-9]+$" | bash -c "cd $DIR;sha1sum -c -"
if [ $? -ne 0 ] ; then
  echo "Decrypted split sums did not successfully verify."
  exit 9
fi

echo "DELETING encrypted splits"
ENCR_FILES_TO_DEL=`ls -1 "$DIR/" | grep "$FILENAME" | grep ".gpg"`
for ENCR_FILE_TO_DEL in $ENCR_FILES_TO_DEL; do
  rm "$DIR/$ENCR_FILE_TO_DEL"
done

echo "JOINING splits"
FILES_TO_JOIN=`ls -1 "$DIR/" | grep "$FILENAME" | grep ".split."`
for FILE_TO_JOIN in $FILES_TO_JOIN; do
  FILE_TO_JOIN_EXT=`echo ${FILE_TO_JOIN#*.} | sed -r 's/\.split\.[0-9]+//'`
  cat "$DIR/$FILE_TO_JOIN" >> "$DIR/$FILENAME.$FILE_TO_JOIN_EXT"
  if [ $? -ne 0 ] ; then
    echo "Joining failed."
    exit 10
  fi
done

echo "CHECKING original file"
sed -r "s/ .*\/(.+)/  \1/g" < $SHA | egrep ".(lzo|gz|tgz|zst)$" | bash -c "cd $DIR;sha1sum -c -"
if [ $? -ne 0 ] ; then
  echo "Original file did not successfully verify."
  exit 11
fi

echo "DELETING decrypted splits"
for FILE_TO_JOIN in $FILES_TO_JOIN; do
  rm "$DIR/$FILE_TO_JOIN"
done
