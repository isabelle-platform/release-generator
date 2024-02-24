pipeline {
  options {
    copyArtifactPermission("*");
  }
  parameters {
    string(name: "FLAVOUR", defaultValue: "intranet", description: "Isabelle flavour")
    string(name: "FTP_CONFIG", defaultValue: "isabelle-intranet-release", description: "Artifact location")
  }
  agent {
    dockerfile {
      filename 'Dockerfile'
      dir '.'
    }
  }

  stages {
    stage('Clean up build folders') {
      steps {
        sh 'rm -rf out || true'
      }
    }
    stage('Download prerequisites') {
      steps {
        dir('ttg') {
          git url: 'https://github.com/maximmenshikov/ttg.git',
              branch: 'main'
        }
      }
    }
    stage('Download for all platforms') {
      stages {
        stage('Download (Linux)') {
          steps {
            withCredentials([usernamePassword(credentialsId: 'relgen_repo_creds', usernameVariable: 'RELEASES_USERNAME', passwordVariable: 'RELEASES_PASSWORD')]) {
              withCredentials([usernamePassword(credentialsId: 'relgen_gh_creds', usernameVariable: 'GH_USERNAME', passwordVariable: 'GH_PASSWORD')]) {
                sh "echo ${params.FLAVOUR} > .flavour"
                sh './release.sh --releases-login "${RELEASES_USERNAME}" --releases-password "${RELEASES_PASSWORD}" --gh-login "${GH_USERNAME}" --gh-password "${GH_PASSWORD}" --flavour "$(cat .flavour)" --out out'
                sh "cp out/release.tar.xz out/${params.FLAVOUR}-${BRANCH_NAME}-${BUILD_NUMBER}.tar.xz"
                sh "cp out/release.tar.xz out/${params.FLAVOUR}-${BRANCH_NAME}-latest.tar.xz"
              }
            }
          }
        }
      }
    }
    stage('Publish artifacts') {
      parallel {
        stage('Publish branch artifacts') {
          steps {
            ftpPublisher alwaysPublishFromMaster: true,
                         continueOnError: false,
                         failOnError: false,
                         masterNodeName: '',
                         paramPublish: null,
                         publishers: [
                          [
                            configName: '$,
                            transfers:
                              [[
                                asciiMode: false,
                                cleanRemote: false,
                                excludes: '',
                                flatten: false,
                                makeEmptyDirs: false,
                                noDefaultExcludes: false,
                                patternSeparator: '[, ]+',
                                remoteDirectory: '${BRANCH_NAME}-${BUILD_NUMBER}',
                                remoteDirectorySDF: false,
                                removePrefix: 'out',
                                sourceFiles: "out/${params.FLAVOUR}-${BRANCH_NAME}-${BUILD_NUMBER}.tar.xz"
                              ]],
                            usePromotionTimestamp: false,
                            useWorkspaceInPromotion: false,
                            verbose: true
                          ]
                        ]
          }
        }
        stage('Publish latest artifacts') {
          steps {
            ftpPublisher alwaysPublishFromMaster: true,
                         continueOnError: false,
                         failOnError: false,
                         masterNodeName: '',
                         paramPublish: null,
                         publishers: [
                          [
                            configName: "${params.FTP_CONFIG}",
                            transfers:
                              [[
                                asciiMode: false,
                                cleanRemote: false,
                                excludes: '',
                                flatten: false,
                                makeEmptyDirs: false,
                                noDefaultExcludes: false,
                                patternSeparator: '[, ]+',
                                remoteDirectory: "${BRANCH_NAME}-latest",
                                remoteDirectorySDF: false,
                                removePrefix: 'out',
                                sourceFiles: "out/${params.FLAVOUR}-${BRANCH_NAME}-latest.tar.xz"
                              ]],
                            usePromotionTimestamp: false,
                            useWorkspaceInPromotion: false,
                            verbose: true
                          ]
                        ]
          }
        }
      }
    }
  }
  post {
    success {
      sh './ttg/ttg_send_notification --env --ignore-bad -- "${JOB_NAME}/${BUILD_NUMBER}: PASSED. See details in ${BUILD_URL}"'
    }
    failure {
      sh './ttg/ttg_send_notification --env --ignore-bad -- "${JOB_NAME}/${BUILD_NUMBER}: FAILED. See details in ${BUILD_URL}"'
    }
    aborted {
      sh './ttg/ttg_send_notification --env --ignore-bad -- "${JOB_NAME}/${BUILD_NUMBER}: ABORTED. See details in ${BUILD_URL}"'
    }
    unstable {
      sh './ttg/ttg_send_notification --env --ignore-bad -- "${JOB_NAME}/${BUILD_NUMBER}: UNSTABLE. See details in ${BUILD_URL}"'
    }
  }
}