#==============================================================================#
#                        iCount Snakemake workflow
#==============================================================================#
# Authors # Igor Ruiz de los Mozos, Charlotte Capitanchik, Tomaz Curk
# Last updated: November 2019


# Install Locally
#================

# Step one: Activate conda environment with Snakemake, iCount and dependencies installed
# Create new environment
# conda env create --name iCount_pipeline --file envs/environment_iCount.yaml
# conda activate iCount_pipeline
# pip install ./iCount/
# Check the install
# iCount

# Run Locally
#================

# Step two: To run locally use command:
# snakemake -k -p --snakefile iCount_snakefile.smk --use-conda
# snakemake -k -p --cores 4 --snakefile iCount_snakefile.smk --use-conda

# dag workflow
# snakemake --snakefile iCount_snakefile.smk --use-conda --dag 2> /dev/null | dot -T png > workflow_bysample.png
# snakemake --snakefile iCount_snakefile.smk --use-conda --rulegraph 2> /dev/null | dot -T png > workflow.png

# Install Cluster
#================

# ENVS on CAMP
# ml Anaconda2/2019.03
# conda create -n iCount_pipeline python=3.6
# conda install -n iCount_pipeline -c bioconda snakemake jinja2 networkx bcftools samtools pysam cutadapt bedtools STAR pip numpy pandas pybedtools numpydoc sphinx matplotlib docutils sphinx_rtd_theme
# conda activate iCount_pipeline
# cd /camp/lab/ulej/working/Igor/Programs/iCount
# pip install ./iCount/
# conda update snakemake

# ENVS2 by IGOR on CAMP
# ml Python/3.6.6-foss-2018b
# ml Anaconda2/2019.03
# conda-env create --file envs/environment_iCount.yaml
# source activate iCount_pipeline2
# cd /camp/lab/ulej/working/Igor/Programs
# pip install ./iCount/

# Run Cluster
#================
# To run in a cluster use command:
# sbatch -J iCount_main -o iCount_%A.out -N 1 -t 3-00:00:00 --wrap="snakemake -k -p --snakefile iCount_snakefile.smk --jobs 99 --use-conda --cluster-config envs/cluster_slurmn.yaml --cluster 'sbatch -J {cluster.name} -N {cluster.n} -c {cluster.c} --mem={cluster.memory} -t {cluster.time} -o {cluster.output} -e {cluster.error}'"

# conda activate iCount_pipeline
# mkdir logs
#

# Dry run
# snakemake -k -p -n -r --snakefile iCount_snakefile.smk --use-conda
# Unlock directory
# snakemake --unlock -k -p --snakefile iCount_snakefile.smk





# LOGGER = logging.getLogger(__name__)
from os.path import join

shell.executable("/bin/bash")

import re
import pandas as pd
import numpy as np
import gzip
import os
import shutil
import tempfile
import pysam
import yaml

# Validate config file!!!
#from snakemake.utils import validate



#~~~~~~~~~~~~~~~~~~~~~* Import config file and samples annotation *~~~~~~~~~~~~~~~~~~~~#
configfile:"config.yaml"
# validate(config, schema="schemas/config.schema.yaml")

samples = pd.read_table(config["samples"]).set_index("5_barcode", drop=False)
#validate(samples, schema="schemas/samples.schema.yaml")

#~~~~~~~~~~~~~~~~~~~~~* Create log folder for cluster run *~~~~~~~~~~~~~~~~~~~~#
logdir = os.path.join(os.getcwd(), config["logdir"])
os.makedirs(logdir, exist_ok=True)




PROJECT = config['project']
#print("Procesing project:", PROJECT)



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~* Final outputs *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
localrules: all

rule all:
    input:
        expand("{genomes_path}/{genome}/{genome}.fa.gz", genome=samples["mapto"].unique(), genomes_path=config['genomes_path']),
        expand("{genomes_path}/{genome}/{genome}.fa.gz.fai", genome=samples["mapto"].unique(), genomes_path=config['genomes_path']),
        expand("{genomes_path}/{genome}/{genome}.gtf.gz", genome=samples["mapto"].unique(), genomes_path=config['genomes_path']),
        expand("{genomes_path}/{genome}/star_index/", genome=samples["mapto"].unique(), genomes_path=config['genomes_path']),
        expand("{genomes_path}/{genome}/segment/{genome}_segment.gtf", project=config['project'], genome=samples["mapto"].unique(), genomes_path=config['genomes_path']),

        "demultiplexed/demux_nomatch.fastq.gz",

        expand("qc/fastqc/raw_fastq_file_fastqc.html"),
        expand("qc/fastqc/raw_fastq_file_fastqc.zip"),
        expand("{project}/qc/fastqc/{barcode}_fastqc.html", project=config['project'], barcode=samples.index),
        expand("{project}/qc/fastqc/{barcode}_fastqc.zip", project=config['project'], barcode=samples.index,),

        expand("{project}/trimmed/demux_{barcode}_trimmed.fastq.gz", project=config['project'], barcode=samples.index),
        expand("{project}/qc/fastqc/{barcode}_trimmed_fastqc.html", project=config['project'], barcode=samples.index),
        expand("{project}/qc/fastqc/{barcode}_trimmed_fastqc.zip", project=config['project'], barcode=samples.index),
        
        expand("{project}/mapped/{barcode}/Aligned.sortedByCoord.out.bam", project=config['project'], barcode=samples.index),

        expand("{project}/xlsites/{barcode}/{barcode}.unique.xl.bed", project=config['project'], barcode=samples.index),
        expand("{project}/xlsites/{barcode}/{barcode}.unique.xl.summary_gene.tsv", project=config['project'], barcode=samples.index),
        expand("{project}/xlsites/{barcode}/{barcode}.unique.xl.annotated_sites_biotype.tab", project=config['project'], barcode=samples.index),
        expand("{project}/xlsites/{barcode}/{barcode}.unique.xl.annotated_sites_gene_id.tab", project=config['project'], barcode=samples.index),
        expand("{project}/xlsites/{barcode}/{barcode}.unique.xl.bedgraph", project=config['project'], barcode=samples.index),
        expand("{project}/xlsites/{barcode}/{barcode}.unique.xl.UCSC.bedgraph", project=config['project'], barcode=samples.index),

        expand("{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.bed", project=config['project'], barcode=samples.index),
        expand("{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.summary_gene.tsv", project=config['project'], barcode=samples.index),
        expand("{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.annotated.biotype.tab", project=config['project'], barcode=samples.index),
        expand("{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.annotated.gene_id.tab", project=config['project'], barcode=samples.index),




#==============================================================================#
#                       Demultiplex
#==============================================================================#

#### Include --mismatches to barcode demultiplex
#### Check if one of the barcodes OR nomatch is not created/found
#### Include 3' barcode demultiplex
rule demultiplex:
    input:
        fastq_file=config['raw_fastq_file']
    output:
        expand("demultiplexed/demux_{barcode}.fastq.gz", barcode=samples.index),
        # "{project}/demultiplexed/demux_{barcode}.fastq.gz",
        "demultiplexed/demux_nomatch.fastq.gz"
    params:
        adapter3=samples["3_adapter"].unique(),                        # Complain if there are more than one 3_adapter
        all_5barcodes = samples["5_barcode"].unique().tolist(),
        dir=directory("demultiplexed")
    shell:
        """
        iCount demultiplex {input.fastq_file} {params.adapter3} {params.all_5barcodes} --out_dir {params.dir} 
        """

# rule move_demultiplex:
#     input:
#         directory("demultiplexed/")
#     output:
#         directory("{project}/demultiplexed/".format(project=config['project']))
#     run:
#         shutil.copytree(input, output)

# -M {log.metrics} 2> {log.log}
# log:
# metrics = "{project}/metrics/demultiplex_metrics.txt",
# log = "{project}/logs/demultiplex_metrics.txt"

#==============================================================================#
#                       Read quality trimming and QC
#==============================================================================#

shell("set -euo pipefail")

rule fastqc_raw:
    input:
        config['raw_fastq_file']
    output:
        html="qc/fastqc/raw_fastq_file_fastqc.html",
        zip="qc/fastqc/raw_fastq_file_fastqc.zip" # the suffix _fastqc.zip is necessary for multiqc to find the file. If not using multiqc, you are free to choose an arbitrary filename
    wrapper:
        "0.38.0/bio/fastqc"


rule fastqc:
    input:
        "demultiplexed/demux_{barcode}.fastq.gz"
    output:
        html="{project}/qc/fastqc/{barcode}_fastqc.html",
        zip="{project}/qc/fastqc/{barcode}_fastqc.zip" # the suffix _fastqc.zip is necessary for multiqc to find the file. If not using multiqc, you are free to choose an arbitrary filename
    log:
        "{project}/logs/fastqc/{barcode}_fastqc.txt"
    wrapper:
        "0.36.0/bio/fastqc"


rule quality_trim:
    input:
        "demultiplexed/demux_{barcode}.fastq.gz"
    output:
        trimmed_reads="{project}/trimmed/demux_{barcode}_trimmed.fastq.gz",
        metrics="{project}/metrics/{barcode}_trimmed.txt"
    params:
        qual_trim=config['qual_trim'],
        minimum_length=config['minimum_length'],
        adapter=config['adapter3'],
    log:
        "{project}/logs/trimmed/{barcode}_trimmed.txt"
    shell:
        """
        iCount cutadapt --qual_trim {params.qual_trim} --minimum_length {params.minimum_length} --file_log 2 --file_logpath {log} --results_file {output.metrics} {input} {output.trimmed_reads} {params.adapter}
        """

rule fastqc_trimmed:
    input:
        "{project}/trimmed/demux_{barcode}_trimmed.fastq.gz"
    output:
        html="{project}/qc/fastqc/{barcode}_trimmed_fastqc.html",
        zip="{project}/qc/fastqc/{barcode}_trimmed_fastqc.zip" # the suffix _fastqc.zip is necessary for multiqc to find the file. If not using multiqc, you are free to choose an arbitrary filename
    log:
        "{project}/logs/fastqc/{barcode}_trimmed_fastqc.log"
    wrapper:
        "0.36.0/bio/fastqc"


#==============================================================================#
#                       Download annotation and index genome
#==============================================================================#


# if the genome is not in the config file will fail with a hint to include path to fasta file and annotation. This to validation of tabular sample file!!

# genomes_path: "iCount_genomes"
# Missing input files(Using '~' in your paths is not allowed as such platform specific syntax is not resolved by Snakemake. In general, try sticking to relative paths for everything inside the working directory.) for rule all:


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~* Check for custom genomes *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#

# Capture iCount available genomes
species_out = subprocess.Popen(["iCount species --source ensembl -r 88"], shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
stdout,stderr = species_out.communicate()
available_genomes=stdout.decode('utf-8').rstrip()
available_genomes=re.split('available: ',str(available_genomes))[-1].split(',')

all_genomes=samples["mapto"].unique()
custom_genomes=np.setdiff1d(all_genomes, available_genomes)
download_genomes=np.setdiff1d(all_genomes, custom_genomes)


# Custom genomes path from config file
def custom_fasta(wildcards):
    return config['custom_genome'][wildcards]['genome_fasta']

def custom_gtf(wildcards):
    return config['custom_genome'][wildcards]['annotation']




# Funcion from icount (call it!!)
def decompress_to_tempfile(fname, context='misc'):
    """
    Decompress files ending with .gz to a temporary file and return filename.
    If file does nto end with .gz, juts return fname.
    Parameters
    ----------
    fname : str
        Path to file to open.
    context : str
        Name of temporary subfolder where temporary file is created.
    Returns
    -------
    str
        Path to decompressed file.
    """
    if fname.endswith('.gz'):
        tmp_dir = os.path.join(context)
        if not os.path.exists(tmp_dir):
            os.makedirs(tmp_dir)

        suffix = '_{:s}'.format(os.path.basename(fname))
        fout = tempfile.NamedTemporaryFile(suffix=suffix, dir=tmp_dir, delete=False)
        fin = gzip.open(fname, 'r')
        shutil.copyfileobj(fin, fout)
        fin.close()
        fout.close()
        return fout.name

    return fname


# Tested with homo_sapiens, mus_musculus; and custom hg19, hg38, mm10, mm15.
rule download_genome:
    output:
        genome_fasta="{genomes_path}/{genome}/{genome}.fa.gz",
        genome_index="{genomes_path}/{genome}/{genome}.fa.gz.fai",
        gtf="{genomes_path}/{genome}/{genome}.gtf.gz",
    params:
        release=config['release'],
    run:
        GENOME=wildcards.genome
        print ("Adquiring genome: %s \n" % (GENOME))


        if GENOME in download_genomes:
            print ("Downloading iCount available genome:", GENOME)
            print ("Downloading genomes could take some time depending on your conection")
            shell("iCount genome --genome {output.genome_fasta} --source ensembl {wildcards.genome} {params.release} --chromosomes MT 19")      # For testing include --chromosomes MT 19
            shell("iCount annotation --annotation {output.gtf} --source ensembl {wildcards.genome} {params.release}")

        elif GENOME in config['custom_genome'].keys():
            fasta_in = custom_fasta(GENOME)
            gtf_in = custom_gtf(GENOME)

            # Move genome data
            shutil.copy(fasta_in, output.genome_fasta)
            shutil.copy(gtf_in, output.gtf)

            # Create fasta index
            temp = decompress_to_tempfile(fasta_in)
            pysam.faidx(temp)  # pylint: disable=no-member
            shutil.move(temp + '.fai', output.genome_index)

        else:
            print ("Your genome %s in the annotation table %s is not in the iCount available genomes %s \n\n" % (GENOME, config["samples"], available_genomes))
            print ("Please, check misspelled genome or include custom genome %s fasta sequence and annotation GTF file in the config file:" % (GENOME))
            print (yaml.dump(config, default_flow_style=False))




rule indexstar_genome:
    input:
        genome_fasta="{genomes_path}/{genome}/{genome}.fa.gz",
        gtf="{genomes_path}/{genome}/{genome}.gtf.gz"
    threads:
        8
    params:
        overhang=config['overhang'],
    output:
        directory("{genomes_path}/{genome}/star_index/")
    shell:
        """
        iCount indexstar --overhang {params.overhang} --annotation {input.gtf} \
        --threads {threads} --genome_sasparsed 2 {input.genome_fasta} {output}
        """


rule segment:
    input:
        gtf="{genomes_path}/{genome}/{genome}.gtf.gz",
        genome_fai="{genomes_path}/{genome}/{genome}.fa.gz.fai"
    output:
        segment="{genomes_path}/{genome}/segment/{genome}_segment.gtf",
    shell:
        """
        iCount segment {input.gtf} {output} {input.genome_fai} 
        """

#==============================================================================#
#                       Map reads
#==============================================================================#


def get_gtf_path(wildcards):
    return ("{0}/{1}/{1}.gtf.gz".format(config['genomes_path'], samples.loc[wildcards.barcode, "mapto"]))

def get_star_index_path(wildcards):
    return ("{0}/{1}/star_index/".format(config['genomes_path'], samples.loc[wildcards.barcode, "mapto"]))

def get_segment_path(wildcards):
    return ("{0}/{1}/segment/{1}_segment.gtf".format(config['genomes_path'], samples.loc[wildcards.barcode, "mapto"]))

def get_templates_dir(wildcards):
    return ("{0}/{1}/segment/".format(config['genomes_path'], samples.loc[wildcards.barcode, "mapto"]))


rule map_reads:
    input:
        trimmed_reads="{project}/trimmed/demux_{barcode}_trimmed.fastq.gz",
        gtf = get_gtf_path,
    output:
        "{project}/mapped/{barcode}/Aligned.sortedByCoord.out.bam"
    params:
        star_index = directory(get_star_index_path),
        outdir=directory("{project}/mapped/{barcode}/"),
        multimax=config['multimax'],
    log:
        "{project}/logs/mapstar/{barcode}_mapstar.log"
    shell:
        """
        iCount mapstar --annotation {input.gtf} --multimax {params.multimax} \
        {input.trimmed_reads} {params.star_index} {params.outdir}
        """


#==============================================================================#
#           Create cross link sites and significant sites (low FDR)
#==============================================================================#


rule xlsites:
    input:
        "{project}/mapped/{barcode}/Aligned.sortedByCoord.out.bam"
    output:
        unique_bed="{project}/xlsites/{barcode}/{barcode}.unique.xl.bed",
        multimapped_bed="{project}/xlsites/{barcode}/{barcode}.multimapped.xl.bed",
        skipped_bam="{project}/xlsites/{barcode}/{barcode}.skipped.xl.bam",
    benchmark:
        "{project}/benchmarks/{barcode}.xlsites.benchmark.tab"
        # repeat("benchmarks/{barcode}.xlsites.benchmark.tab", 3)
    log:
        "{project}/logs/xlsites/{barcode}.xlsites.log"
    shell:
        """
        iCount xlsites {input} {output.unique_bed} {output.multimapped_bed} {output.skipped_bam} -M {log}
        """

rule sig_xlsites:
    input:
        xlsites="{project}/xlsites/{barcode}/{barcode}.unique.xl.bed",
        segment_file=get_segment_path
    output:
        sigxls="{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.bed",
        scores="{project}/sig_xlsites/{barcode}/{barcode}.scores.tsv"
    benchmark:
        "{project}/benchmarks/{barcode}.sig_xlsites.benchmark.txt"
    shell:
        """
        iCount peaks {input.segment_file} {input.xlsites} {output.sigxls} --scores {output.scores}
        """


#==============================================================================#
#             Annotate cross link sites, summaries and obtain bedgraph
#==============================================================================#


rule annotate_xlsites:
    input:
        xlsites = "{project}/xlsites/{barcode}/{barcode}.unique.xl.bed"
    output:
        biotype="{project}/xlsites/{barcode}/{barcode}.unique.xl.annotated_sites_biotype.tab",
        gene_id="{project}/xlsites/{barcode}/{barcode}.unique.xl.annotated_sites_gene_id.tab"
    params:
        templates_dir = get_templates_dir,
        segment = get_segment_path,
        out_dir = "{project}/annotated/",
    shell:
        """
        iCount annotate --subtype biotype {params.segment} {input.xlsites} {output.biotype}
        iCount annotate --subtype gene_id {params.segment} {input.xlsites} {output.gene_id}
        """

rule summary:
    input:
        xlsites="{project}/xlsites/{barcode}/{barcode}.unique.xl.bed"
    output:
        gene="{project}/xlsites/{barcode}/{barcode}.unique.xl.summary_gene.tsv",
        type="{project}/xlsites/{barcode}/{barcode}.unique.xl.summary_type.tsv",
        subtype="{project}/xlsites/{barcode}/{barcode}.unique.xl.summary_subtype.tsv"
    params:
        templates_dir=get_templates_dir,
        segment = get_segment_path,
        out_dir="{project}/xlsites/{barcode}/",
        rename_gene="{project}/xlsites/{barcode}/summary_gene.tsv",
        rename_type="{project}/xlsites/{barcode}/summary_type.tsv",
        rename_subtype="{project}/xlsites/{barcode}/summary_subtype.tsv",
    shell:
        """
        iCount summary --templates_dir {params.templates_dir} {params.segment} {input.xlsites} {params.out_dir}
        mv {params.rename_gene} {output.gene}
        mv {params.rename_type} {output.type}
        mv {params.rename_subtype} {output.subtype}
        """

def is_empty(fname):
    print(fname + " file is empty.")
    return os.stat(str(fname)).st_size == 0


# Create a new empty file.
def createNewFile(fname):
    file_object = open(fname, 'w')
    # file_object.write('File is created.')
    print(fname + " has been created. ")



rule annotate_sig_xlsites:
    input:
        sig_xlsites = "{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.bed"
    output:
        biotype="{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.annotated.biotype.tab",
        gene_id="{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.annotated.gene_id.tab"
    params:
        templates_dir = get_templates_dir,
        segment = get_segment_path,
        out_dir = "{project}/sig_xlsites/{barcode}/",
    run:
        if is_empty(input.sig_xlsites):
            print ("File", input.sig_xlsites, "is empty. Creating output files:", output.biotype, output.gene_id, " to continue snakemake pipeline")
            createNewFile(output.biotype)
            createNewFile(output.gene_id)
        else:
            shell("iCount annotate --subtype biotype {params.segment} {input.sig_xlsites} {output.biotype}")
            shell("iCount annotate --subtype gene_id {params.segment} {input.sig_xlsites} {output.gene_id}")



rule summary_sig:
    input:
        sig_xlsites = "{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.bed"
    output:
        gene = "{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.summary_gene.tsv",
        type = "{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.summary_type.tsv",
        subtype = "{project}/sig_xlsites/{barcode}/{barcode}.sig_sites.summary_subtype.tsv",
    params:
        templates_dir = get_templates_dir,
        segment = get_segment_path,
        out_dir = "{project}/sig_xlsites/{barcode}/",
        rename_gene = "{project}/sig_xlsites/{barcode}/summary_gene.tsv",
        rename_type = "{project}/sig_xlsites/{barcode}/summary_type.tsv",
        rename_subtype = "{project}/sig_xlsites/{barcode}/summary_subtype.tsv",
    run:
        if is_empty(input.sig_xlsites):
            print ("File", input.sig_xlsites, "is empty. Creating output file:", output.gene,
                   " to continue snakemake pipeline")
            createNewFile(output.gene)
            createNewFile(output.type)
            createNewFile(output.subtype)
        else:
            shell("iCount summary --templates_dir {params.templates_dir} {params.segment} {input.sig_xlsites} {params.out_dir}")
            shell("mv {params.rename_gene} {output.gene}")
            shell("mv {params.rename_type} {output.type}")
            shell("mv {params.rename_subtype} {output.subtype}")


def bedgraph_description(wildcards):
    return ("{project}_{sample_name}_{protein}_{method}_{mapto}".format(project=config['project'], sample_name=samples.loc[wildcards.barcode, "sample_name"], mapto=samples.loc[wildcards.barcode, "mapto"], method=samples.loc[wildcards.barcode, "method"],	protein=samples.loc[wildcards.barcode, "protein"],	cells_tissue=samples.loc[wildcards.barcode, "cells/tissue"],	condition=samples.loc[wildcards.barcode, "condition"],))


rule bedgraph:
    input:
        xlsites="{project}/xlsites/{barcode}/{barcode}.unique.xl.bed",
    output:
        bedgraph="{project}/xlsites/{barcode}/{barcode}.unique.xl.bedgraph",
    params:
        name=bedgraph_description,
        description=bedgraph_description,
        visibility="full",
        priority="20",
        color="120,101,172",
        alt_color="200,120,59",
        max_height_pixels="100:50:0",
    run:
        print("params.description", params.description)
        print ("output.bedgraph", output.bedgraph)

        shell("iCount bedgraph --name \"{params.name}.unique.xl.bedgraph\" --description \"{params.description}\" --visibility \"{params.visibility}\" --priority \"{params.priority}\" --color \"{params.color}\" --alt_color \"{params.alt_color}\" --max_height_pixels \"{params.max_height_pixels}\" {input.xlsites} {output.bedgraph}")




def bedgraph_header(wildcards):
    # db=\"{mapto}\" removed
    # return ("{project}_{sample_name}_{protein}_{method}_{mapto}".format(project=config['project'], sample_name=samples.loc[wildcards.barcode, "sample_name"], mapto=samples.loc[wildcards.barcode, "mapto"], method=samples.loc[wildcards.barcode, "method"],	protein=samples.loc[wildcards.barcode, "protein"],	cells_tissue=samples.loc[wildcards.barcode, "cells/tissue"],	condition=samples.loc[wildcards.barcode, "condition"],))
    return ("track type=bedGraph name=\"{project}_{sample_name}_{protein}_{method}_{mapto}_unique.xl.bedgraph.bed\" description=\"{project}_{sample_name}_{protein}_{method}_{mapto}\" "
            "color=\"120,101,172\"  mapped_to=\"{mapto}\" altColor=\"200,120,59\" lib_id=\"{project}\" maxHeightPixels=\"100:50:0\" visibility=\"full\" "
            "tissue=\"{cells_tissue}\" protein=\"{protein}\" species=\"{mapto}\" condition=\"{condition}\" res_type=\"T\" priority=\"20\" \n".format(project=config['project'], sample_name=samples.loc[wildcards.barcode, "sample_name"], mapto=samples.loc[wildcards.barcode, "mapto"], method=samples.loc[wildcards.barcode, "method"],	protein=samples.loc[wildcards.barcode, "protein"],	cells_tissue=samples.loc[wildcards.barcode, "cells/tissue"],	condition=samples.loc[wildcards.barcode, "condition"],))


def get_genome(wildcards):
    return ("{0}".format(samples.loc[wildcards.barcode, "mapto"]))


rule bedgraphUCSC:
    input:
        xlsites="{project}/xlsites/{barcode}/{barcode}.unique.xl.bed",
    output:
        bedgraph="{project}/xlsites/{barcode}/{barcode}.unique.xl.UCSC.bedgraph",
    params:
        header=bedgraph_header,
        genome=get_genome,
    run:
        # Convert ENSMBL to UCSC. Thanks to Devon Ryan for creation of mapping tables
        # If your genome is not included please check: https://github.com/dpryan79/ChromosomeMappings
        d = {}
        if params.genome == 'homo_sapiens':
            f = open("data/GRCh38_ensembl2UCSC.txt")
        elif params.genome == 'mus_musculus':
            f = open("data/GRCm38_ensembl2UCSC.txt")
        else:
            print("Please add mapping file to trasnform your genome coordinates to UCSC compatible chromosomes")
            f = ""

        for line in f:
            cols = line.strip().split("\t")
            if len(cols) < 2 or cols[1] == "":
                continue
            d[cols[0]] = cols[1]

        f.close()

        fin = open(input.xlsites)
        fout = open(output.bedgraph, "w")
        fout.write(params.header)
        line = fin.readline()
        while line:
            col = line.rstrip('\n').rsplit('\t')
            chr = col[0]
            count = col[4]
            strand = col[5]
            if strand == '-':
                count = '-' + count
            fout.write(d[chr] + '\t' + col[1] + '\t' + col[2] + '\t' + count + '\n')
            line = fin.readline()

        fin.close()
        fout.close()


#==============================================================================#
#                       Group analysis
#==============================================================================#


# rule group:


#==============================================================================#
#                       RNAmaps & Kmers
#==============================================================================#


# rule RNAmaps:
# rule kmers:
# rule clean:

#==============================================================================#
#                       Metrics and experiment QC
#==============================================================================#

# multiQC implementation
# total reads
# demultiplex %
# total xlistes % of PCR duplication
# total peaks
# biotypes per sample
# Lits of more abundant binders
# More...?