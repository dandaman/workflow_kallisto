'''
kallisto.snakefile
Kamil Slowikowski
https://github.com/slowkow/snakefiles

mildly adapted by Daniel Lang

Quantify transcript expression in paired-end RNA-seq data with kallisto
-----------------------------------------------------------------------

Requirements:

  kallisto
	  https://pachterlab.github.io/kallisto/download.html

Usage: 

  snakemake \
  	--snakefile kallisto.snakefile \
  	--configfile config.yml \
  	--jobs 999 \
  	--cluster 'your syntax to submit jobs on the cluster'
'''

import json
from os.path import join, basename, dirname
from subprocess import check_output
from itertools import chain

# Globals ---------------------------------------------------------------------

configfile: 'config.yml'

# Number of bootstrap replicates for quant
BOOT=100
# Full path to an uncompressed FASTA file with all chromosome sequences.
CDNA = config['CDNA']

# Full path to a folder where intermediate output files will be created.
OUT_DIR = config['OUT_DIR']

# Samples and their corresponding filenames.
FILES = json.load(open(config['SAMPLES_JSON']))
SAMPLES = sorted(FILES.keys())

KALLISTO_VERSION = check_output("echo $(kallisto)", shell=True).split()[1]

# Functions -------------------------------------------------------------------

def rstrip(text, suffix):
	# Remove a suffix from a string.
	if not text.endswith(suffix):
		return text
	return text[:len(text)-len(suffix)]

# Rules -----------------------------------------------------------------------

localrules: all, unzip_transcriptome, kallisto_index, zip_transcriptome, collate_kallisto, n_processed

rule all:
	input:
		'abundance.tsv.gz',
		'n_processed.tsv.gz',
		CDNA + ".gz",
		expand(join(OUT_DIR, '{sample}', 'abundance.tsv.gz'), sample=SAMPLES)

rule unzip_transcriptome:
	input:
		CDNA + ".gz"
	output:
		CDNA
	benchmark:
		"benchmarks/gunzip.txt"
	shell:
		"gunzip {input}"
	log:
		'log/unzip_transcriptome.log'


rule kallisto_index:
	input:
		cdna = CDNA
	output:
		index = join(dirname(CDNA), 'kallisto', rstrip(basename(CDNA), '.fa'))
	log:
		'log/kallisto.index.log'
	benchmark:
		"benchmarks/indexing.txt"	
	version:
		KALLISTO_VERSION
	run:
		# Record the kallisto version number in the log file.
		shell('echo $(kallisto index) &> {log}')
		# Write stderr and stdout to the log file.
		shell('kallisto index'
			  ' --index={output.index}'
			  ' --kmer-size=21'
			  ' --make-unique'
			  ' {input.cdna}'
			  ' >> {log} 2>&1')

rule zip_transcriptome:
	input:
		cdna = CDNA,
		index = join(dirname(CDNA), 'kallisto', rstrip(basename(CDNA), '.fa'))
	output:
		CDNA + ".gz"
	benchmark:
		"benchmarks/gzip.txt"
	shell:
		"gzip {input.cdna}"
	log:
		'log/zip_transcriptome.log'

rule kallisto_quant:
	input:
		r1 = lambda wildcards: FILES[wildcards.sample]['R1'],
		r2 = lambda wildcards: FILES[wildcards.sample]['R2'],
		index = rules.kallisto_index.output.index
	output:
		join(OUT_DIR, '{sample}', 'abundance.tsv'),
		join(OUT_DIR, '{sample}', 'run_info.json')
	version:
		KALLISTO_VERSION
	benchmark:
		"benchmarks/{sample}.quant.txt"
	threads:
		4
	resources:
		mem = 4000
	run:
		fastqs = ' '.join(chain.from_iterable(zip(input.r1, input.r2)))
		shell('kallisto quant' +
			' --threads={threads}' + 
			' --bootstrap-samples=%s' % (BOOT) +
			' --index={input.index}' +
			' --output-dir=' + join(OUT_DIR, '{wildcards.sample}') +
			' ' + fastqs)
	log:
		'log/kallisto_quant.{sample}.log'


rule collate_kallisto:
	input:
		expand(join(OUT_DIR, '{sample}', 'abundance.tsv'), sample=SAMPLES)
	output:
		'abundance.tsv.gz'
	benchmark:
		"benchmarks/collate.txt"
	run:
		import gzip

		b = lambda x: bytes(x, 'UTF8')

		# Create the output file.
		with gzip.open(output[0], 'wb') as out:

			# Print the header.
			header = open(input[0]).readline()
			out.write(b('sample\t' + header))

			for i in input:
				sample = basename(dirname(i))
				lines = open(i)
				# Skip the header in each file.
				lines.readline()
				for line in lines:
					# Skip transcripts with 0 TPM.
					fields = line.strip().split('\t')
					if float(fields[4]) > 0:
						out.write(b(sample + '\t' + line))
	log:
		'log/collate_kallisto.log'


rule n_processed:
	input:
		expand(join(OUT_DIR, '{sample}', 'run_info.json'), sample=SAMPLES)
	output:
		'n_processed.tsv.gz'
	benchmark:
		'benchmarks/n_processed.txt'
	run:
		import json
		import gzip

		b = lambda x: bytes(x, 'UTF8')

		with gzip.open(output[0], 'wb') as out:
			out.write(b('sample\tn_processed\n'))

			for f in input:
				sample = basename(dirname(f))
				n = json.load(open(f)).get('n_processed')
				out.write(b('{}\t{}\n'.format(sample, n)))
	log:
		'log/n_processed.log'


rule gzip_abundances:
	input:
		'abundance.tsv.gz',
		'n_processed.tsv.gz',
		expand(join(OUT_DIR, '{sample}', 'abundance.tsv'), sample=SAMPLES)
	output:
		expand(join(OUT_DIR, '{sample}', 'abundance.tsv.gz'), sample=SAMPLES)
	run:
		for f in input:
			shell("gzip {file}".format(file=f))
	log:
		'log/gzip_abundances.{sample}.log'
