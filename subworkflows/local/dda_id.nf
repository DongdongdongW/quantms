//
// MODULE: Local to the pipeline
//
include { DECOYDATABASE } from '../../modules/local/openms/decoydatabase/main'
include { CONSENSUSID   } from '../../modules/local/openms/consensusid/main'
include { EXTRACTPSMFEATURES } from '../../modules/local/openms/extractpsmfeatures/main'
include { PERCOLATOR         } from '../../modules/local/openms/thirdparty/percolator/main'
include { FALSEDISCOVERYRATE as FDRIDPEP } from '../../modules/local/openms/falsediscoveryrate/main'
include { IDPEP                          } from '../../modules/local/openms/idpep/main'
include { PSMCONVERSION                  } from '../../modules/local/extract_psm/main'

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { DATABASESEARCHENGINES } from './databasesearchengines'
include { PSMFDRCONTROL         } from './psmfdrcontrol'

workflow DDA_ID {
    take:
    ch_file_preparation_results
    ch_database_wdecoy
    ch_spectrum_data

    main:

    ch_software_versions = Channel.empty()

    //
    // SUBWORKFLOW: DatabaseSearchEngines
    //
    DATABASESEARCHENGINES (
        ch_file_preparation_results,
        ch_database_wdecoy
    )
    ch_software_versions = ch_software_versions.mix(DATABASESEARCHENGINES.out.versions.ifEmpty(null))
    ch_id_files = DATABASESEARCHENGINES.out.ch_id_files_idx

    ch_id_files.branch{ meta, filename ->
        sage: filename.name.contains('sage')
            return [meta, filename]
        nosage: true
            return [meta, filename]
    }.set{ch_id_files_branched}


    //
    // SUBWORKFLOW: Rescoring
    //
    if (params.skip_rescoring == false) {
        if (params.posterior_probabilities == 'percolator') {
            EXTRACTPSMFEATURES(ch_id_files_branched.nosage)
            ch_id_files_feats = ch_id_files_branched.sage.mix(EXTRACTPSMFEATURES.out.id_files_feat)
            ch_software_versions = ch_software_versions.mix(EXTRACTPSMFEATURES.out.version)
            PERCOLATOR(ch_id_files_feats)
            ch_software_versions = ch_software_versions.mix(PERCOLATOR.out.version)
            ch_consensus_input = PERCOLATOR.out.id_files_perc
        }


        if (params.posterior_probabilities != 'percolator') {
            ch_fdridpep = Channel.empty()
            if (params.search_engines.split(",").size() == 1) {
                FDRIDPEP(ch_id_files)
                ch_software_versions = ch_software_versions.mix(FDRIDPEP.out.version)
                ch_id_files = Channel.empty()
                ch_fdridpep = FDRIDPEP.out.id_files_idx_ForIDPEP_FDR
            }
            IDPEP(ch_fdridpep.mix(ch_id_files))
            ch_software_versions = ch_software_versions.mix(IDPEP.out.version)
            ch_consensus_input = IDPEP.out.id_files_ForIDPEP
        }

        //
        // SUBWORKFLOW: PSMFDRCONTROL
        //
        ch_psmfdrcontrol     = Channel.empty()
        ch_consensus_results = Channel.empty()
        if (params.search_engines.split(",").size() > 1) {
            CONSENSUSID(ch_consensus_input.groupTuple(size: params.search_engines.split(",").size()))
            ch_software_versions = ch_software_versions.mix(CONSENSUSID.out.version.ifEmpty(null))
            ch_psmfdrcontrol = CONSENSUSID.out.consensusids
            ch_consensus_results = CONSENSUSID.out.consensusids
        } else {
            ch_psmfdrcontrol = ch_consensus_input
        }

        PSMFDRCONTROL(ch_psmfdrcontrol)
        ch_software_versions = ch_software_versions.mix(PSMFDRCONTROL.out.version.ifEmpty(null))

        //
        // Extract PSMs and export parquet format
        //
        ch_spectrum_data.view()
        PSMFDRCONTROL.out.id_filtered.view()
        PSMCONVERSION(PSMFDRCONTROL.out.id_filtered.combine(ch_spectrum_data, by: 0))

    } else {
        PSMCONVERSION(ch_id_files.combine(ch_spectrum_data, by: 0))
    }


    emit:
    version                 = ch_software_versions
}
