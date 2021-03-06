#!/bin/bash


### TODO Add filter to get genes for a cgMLST, or accessory scheme
### TODO Change names/args to reflect that the scheme initially created
        ### is NOT a cgmlst scheme nor a pangenome scheme
        ### nor is it a pangenome scheme
### TODO Fix divide_schemes.R so that threshold for absence is no longer hardcoded

if test $# -eq 0; then
    echo "No arguments provided!"
    exit 1
fi

SRC_DIR=$(cd "$(dirname "$0")/.."; pwd)
SCRIPT_DIR=$(cd "$(dirname "$0")"; pwd)
T="$(date +%s)"
function fullpath {

    echo "$( cd "$(dirname "$1")"; pwd)/$(basename "$1")"
}


while test $# -gt 0; do

    case "$1" in
        
        -h|--help)
            echo "Required arguments:"
            echo "--work-dir         Working directory for this script."
            echo "--reference        Fasta filename (not path) within --genomes path to be used as reference."
            echo "--genomes          Path to directory containing genomes as FASTAS."
            exit 0
            ;;
        
        --work-dir)
            shift
            if test $# -gt 0; then
                
                export WORKDIR=$(echo $(fullpath "$1"))/
            else
                echo "You need to give me a work directory."
                exit 1
            fi
            shift
            ;;

        --genomes)
            shift
            if test $# -gt 0; then
                export GENOMES=$(echo $(fullpath "$1"))/
            else
                echo "No genomes specified!"
                exit 1
            fi
            shift
            ;;

        --reference)
            shift
            if test $# -gt 0; then
                export REFERENCE=$1
            else
                echo "No reference genomes provided!"
                exit 1
            fi
            shift
            ;;

    esac
done

if [ ! -f ${GENOMES}/${REFERENCE} ]; then
    echo "${GENOMES}/${REFERENCE} does not exist."
    exit 1
fi


function fasta_rename {

    FASTANAME=$( head -n 1 $1 | cut -d' ' -f1 | sed 's/>//')
    FASTANAME=${FASTANAME}.fasta
    sed -i 's/^\(>.*\)/>1/' $1
    mv $1 $FASTANAME

}

function split_args {

    OIFS=$IFS
    IFS=','
    arr=$1
    IFS=$OIFS 
    echo arr
}

### Set up directories ###
echo $WORKDIR
echo $GENOMES

mkdir $WORKDIR
cd $WORKDIR 

mkdir alleles blast_out jsons msa temp

### Get non-redundant gene set ###

PROKKA_PREFIX=$( echo $REFERENCE | sed 's/\(.*\)\..*/\1/' ) 

printf "\nRunning Prokka\n"

prokka --outdir prokka_out/ \
       --prefix $PROKKA_PREFIX \
       --locustag $PROKKA_PREFIX \
       --cpus 0 \
       ${GENOMES}${REFERENCE}

### all-vs-all BLAST search to filter homologues
printf "\nStarting all-vs-all BLAST search of CDS\n"
makeblastdb -in prokka_out/${PROKKA_PREFIX}.ffn -dbtype nucl \
            -out temp/${PROKKA_PREFIX}_db
blastn -query prokka_out/${PROKKA_PREFIX}.ffn \
       -db temp/${PROKKA_PREFIX}_db \
       -num_threads $( nproc ) \
       -outfmt 10 \
       -out blast_out/all_vs_all.csv

printf "\nFiltering out homologues\n"
# AVA filters the all-vs-all search for homologues
    # Thresholds are defaulted as 90% PID and 50% length 
    # Only the longest variant is kept
python ${SCRIPT_DIR}/ava.py --seq prokka_out/${PROKKA_PREFIX}.ffn \
                            --result blast_out/all_vs_all.csv \
                            --out blast_out/non_redundant.fasta


### Create .markers file for MIST ###
printf "\nSplitting to discrete fastas.\n"
csplit --quiet --prefix alleles/ -z prokka_out/${PROKKA_PREFIX}.ffn '/>/' '{*}'

cd alleles/

for i in $( ls ); do
    fasta_rename $i
done

cd $WORKDIR

printf "\nBuilding reference genome .markers file\n"
python ${SCRIPT_DIR}/marker_maker.py --fastas alleles/ \
                       --out wgmlst.markers \
                       --test wgmlst

### run MIST ###
printf "\nRunning MIST in parallel.\n"

# A hack that will find the shortest path to MIST
    # The notion is that it won't accidentally find 
    # debugging binaries buried in the project directory
parallel mono $( locate MIST.exe | sort -n | tail -n 1 ) \
         -t wgmlst.markers \
         -T temp/ \
         -a alleles/ \
         -b -j jsons/{/.}.json \
         {} ::: ${GENOMES}/*.fasta

### Update allele definitions ### 
printf "\nUpdating allele definitions.\n"
python ${SCRIPT_DIR}/update_definitions.py --alleles alleles/ \
                                           --jsons jsons/ \
                                            --test wgmlst

### Align genes with clustalo ###
printf "\nAligning genes.\n"
parallel clustalo -i {} -o msa/{/} ::: alleles/*.fasta

### Divide Reference-based calls into core, genome, accessory schemes ###
printf "\nParsing JSONs.\n"
python ${SCRIPT_DIR}/json2csv.py --jsons jsons/ \
                                 --test wgmlst \
                                 --out  ${PROKKA_PREFIX}_calls.csv

printf "\nDividing markers into core and accessory schemes.\n"
Rscript ${SCRIPT_DIR}/divide_schemes.R ${PROKKA_PREFIX}_calls.csv wgmlst.markers

printf "\nScript complete at `date`\n"

T="$(($(date +%s)-T))"
printf "Total run time: %02d:%02d:%02d:%02d\n" "$((T/86400))" "$((T/3600%24))" "$((T/60%60))" "$((T%60))"

