pipeline {
  // Download releases from GitHub and deploy them
  agent { label 'built-in' }

  options {
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
  }

  triggers {
    // Poll GitHub every 5 minutes for new commits
    pollSCM('H/5 * * * *')
  }

  environment {
    BOT_NAME = 'terrain_bot'
    STATE_NAME = 'terrain_bot'
    RELEASE_DIR = "/opt/ergon/releases/${BOT_NAME}"
    // Terrain bot releases are published from ergon-automation-labs/ergon_terrain repo
    GITHUB_REPO = "ergon-automation-labs/ergon-terrain"
    SALT_TARGET = '-G bot_army_node_type:air'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Download Build Artifact') {
      steps {
        sh '''
          echo "==============================================="
          echo "Downloading pre-built release from GitHub"
          echo "==============================================="

          # Get the latest published release (not a draft)
          LATEST_RELEASE=$(gh api repos/${GITHUB_REPO}/releases \
            -q '.[] | select(.draft==false) | .tag_name' | head -1)

          if [ -z "$LATEST_RELEASE" ]; then
            echo "ERROR: No published release found on GitHub"
            exit 1
          fi

          echo "Latest release: $LATEST_RELEASE"

          # Download the tarball asset
          echo "Downloading: ${BOT_NAME}-*.tar.gz"
          mkdir -p ./release-artifact

          gh release download $LATEST_RELEASE \
            --repo ${GITHUB_REPO} \
            --pattern "*.tar.gz" \
            -D ./release-artifact

          echo "✓ Release downloaded successfully"

          # Extract tarball
          cd ./release-artifact
          TARBALL=$(ls -1 *.tar.gz | head -1)
          echo "Extracting: $TARBALL"
          tar -xzf "$TARBALL"
          rm "$TARBALL"
          ls -la
          cd ..
        '''
      }
    }

    stage('Deploy') {
      steps {
        sh '''
          echo "==============================================="
          echo "Deploying release"
          echo "==============================================="
          echo "Start time: $(date)"

          TIMESTAMP=$(date +%Y%m%d%H%M%S)
          DEST="${RELEASE_DIR}/releases/${TIMESTAMP}"

          echo "Creating release directory..."
          mkdir -p "${DEST}"

          echo "Copying release artifacts..."
          cp -r ./release-artifact/* "${DEST}/"

          echo "Updating current symlink..."
          ln -sfn "${DEST}" "${RELEASE_DIR}/current"

          echo "Deploying service via Salt..."
          salt_apply() {
            local state=$1 attempt=0
            until sudo /opt/salt/salt ${SALT_TARGET} state.apply $state; do
              attempt=$((attempt + 1))
              if [ $attempt -ge 3 ]; then echo "salt state.apply $state failed after 3 attempts"; return 1; fi
              echo "Salt busy, retrying in 30s... (attempt $attempt/3)"
              sleep 30
            done
          }
          salt_apply common.core
          salt_apply common.schemas
          salt_apply bots.${STATE_NAME}

          echo "Restarting service to pick up new release..."
          sudo launchctl unload /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist 2>/dev/null || true
          sleep 2

          # Load service with error checking
          if ! sudo launchctl load -w /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist; then
            echo "ERROR: Failed to load service via launchctl"
            exit 1
          fi

          echo "Checking service health..."
          /opt/bot_army/scripts/health_check.sh ${BOT_NAME}

          echo "Deploy complete!"
          echo "Completion time: $(date)"
        '''
      }
    }

    stage('Publish Deploy Event') {
      steps {
        sh '''
          echo "==============================================="
          echo "Publishing deploy event"
          echo "==============================================="
          echo "Start time: $(date)"

          # Get the release binary path
          RELEASE_BIN="${RELEASE_DIR}/current/terrain_bot/bin/terrain_bot"

          if [ ! -f "$RELEASE_BIN" ]; then
            echo "⚠️  Release binary not found at $RELEASE_BIN"
            echo "Publishing deploy_failed event"
            PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"failed"}
EOF
)
            /opt/bot_army/scripts/nats_publish.sh ops.deploy.terrain_bot "$PAYLOAD" || echo "⚠️  NATS publish failed (non-blocking)"
            exit 1
          fi

          echo "Publishing deploy_started event..."
          PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"started"}
EOF
)
          /opt/bot_army/scripts/nats_publish.sh ops.deploy.terrain_bot "$PAYLOAD" || echo "⚠️  NATS publish failed (non-blocking)"

          echo "Running migrations..."
          $RELEASE_BIN eval 'BotArmyTerrain.Release.migrate()' && {
            echo "✓ Migrations complete"
            echo "Publishing deploy_complete event..."
            VERSION=$(awk '{print $2}' "$RELEASE_DIR/current/terrain_bot/releases/start_erl.data" 2>/dev/null || echo "unknown")
            PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"complete","version":"${VERSION}"}
EOF
)
            /opt/bot_army/scripts/nats_publish.sh ops.deploy.terrain_bot "$PAYLOAD" || echo "⚠️  NATS publish failed (non-blocking)"
          } || {
            echo "⚠️  Migration failed"
            echo "Publishing deploy_failed event..."
            PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"failed"}
EOF
)
            /opt/bot_army/scripts/nats_publish.sh ops.deploy.terrain_bot "$PAYLOAD" || echo "⚠️  NATS publish failed (non-blocking)"
            exit 1
          }

          echo "Publish Deploy Event complete!"
          echo "Completion time: $(date)"
        '''
      }
    }

    stage('Run Migrations') {
      steps {
        sh '''
          echo "==============================================="
          echo "Running database create + migrations"
          echo "==============================================="

          RELEASE_BIN="${RELEASE_DIR}/current/terrain_bot/bin/terrain_bot"

          if [ ! -f "$RELEASE_BIN" ]; then
            echo "ERROR: Release binary not found at $RELEASE_BIN"
            exit 1
          fi

          echo "Running: $RELEASE_BIN eval 'BotArmyTerrain.Release.create()'"
          $RELEASE_BIN eval 'BotArmyTerrain.Release.create()'

          echo "Running: $RELEASE_BIN eval 'BotArmyTerrain.Release.migrate()'"
          $RELEASE_BIN eval 'BotArmyTerrain.Release.migrate()'

          echo "Running: $RELEASE_BIN eval 'BotArmyTerrain.Release.migrate_graph()'"
          $RELEASE_BIN eval 'BotArmyTerrain.Release.migrate_graph()'

          echo "✓ All migrations complete"
        '''
      }
    }

  }

  post {
    success {
      sh '''
        # Extract version from the deployed release (not workspace - may be cleaned)
        START_ERL="${RELEASE_DIR}/current/terrain_bot/releases/start_erl.data"
        if [ -f "$START_ERL" ]; then
          VERSION=$(awk '{print $2}' "$START_ERL")
        else
          VERSION="unknown"
        fi

        TIMESTAMP=$(basename $(readlink "${RELEASE_DIR}/current"))
        GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

        PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"success","version":"${VERSION}","release":"${TIMESTAMP}","sha":"${GIT_SHA}"}
EOF
)
        echo "📢 Notifying NATS of successful deployment..."
        /opt/bot_army/scripts/nats_publish.sh ops.builds.${BOT_NAME} "$PAYLOAD" || echo "⚠️  NATS notification failed (non-blocking)"
      '''
    }
    failure {
      sh '''
        PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"failed"}
EOF
)
        echo "📢 Notifying NATS of failed deployment..."
        /opt/bot_army/scripts/nats_publish.sh ops.builds.${BOT_NAME} "$PAYLOAD" || echo "⚠️  NATS notification failed (non-blocking)"
      '''
    }
    always {
      cleanWs()
    }
  }
}
