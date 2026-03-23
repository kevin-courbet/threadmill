#!/bin/bash
# Regenerates the UITests Xcode project's Threadmill source file references
# from the filesystem. Run after adding/removing Swift files.
#
# Usage: bash Scripts/sync_xcodeproj.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$REPO_ROOT/UITests/ThreadmillUITests.xcodeproj/project.pbxproj"

if [ ! -f "$PBXPROJ" ]; then
    echo "error: $PBXPROJ not found"
    exit 1
fi

# Collect all Swift source files (exclude _Fridge and threadmill-relay)
SOURCE_FILES=$(find "$REPO_ROOT/Sources/Threadmill" -name '*.swift' \
    -not -path '*/_Fridge/*' \
    | sort)

# Generate deterministic UUIDs from file paths (md5 hash truncated to 24 hex chars)
uuid_for_file() {
    echo -n "$1" | md5 | head -c 24 | tr '[:lower:]' '[:upper:]'
}

# Build PBXBuildFile entries (B1 prefix pattern)
BUILD_FILE_ENTRIES=""
FILE_REF_ENTRIES=""
SOURCE_BUILD_REFS=""
FILE_GROUP_REFS=""

for filepath in $SOURCE_FILES; do
    relpath="${filepath#$REPO_ROOT/}"  # e.g., Sources/Threadmill/App/AppDelegate.swift
    filename=$(basename "$filepath")
    
    hash=$(uuid_for_file "$relpath")
    build_uuid="C1${hash:0:22}"
    ref_uuid="C2${hash:0:22}"
    
    BUILD_FILE_ENTRIES+="		${build_uuid} /* ${filename} in Sources */ = {isa = PBXBuildFile; fileRef = ${ref_uuid} /* ${filename} */; };\n"
    FILE_REF_ENTRIES+="		${ref_uuid} /* ${filename} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = \"${filename}\"; path = \"../${relpath}\"; sourceTree = SOURCE_ROOT; };\n"
    SOURCE_BUILD_REFS+="				${build_uuid} /* ${filename} in Sources */,\n"
    FILE_GROUP_REFS+="				${ref_uuid} /* ${filename} */,\n"
done

# Also include the UITest files
for testfile in "$REPO_ROOT/UITests/ThreadmillUITests/"*.swift; do
    filename=$(basename "$testfile")
    hash=$(uuid_for_file "UITests/$filename")
    build_uuid="A1${hash:0:22}"
    ref_uuid="A2${hash:0:22}"
    
    BUILD_FILE_ENTRIES+="		${build_uuid} /* ${filename} in Sources */ = {isa = PBXBuildFile; fileRef = ${ref_uuid} /* ${filename} */; };\n"
    FILE_REF_ENTRIES+="		${ref_uuid} /* ${filename} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${filename}; sourceTree = \"<group>\"; };\n"
    SOURCE_BUILD_REFS+="				${build_uuid} /* ${filename} in Sources */,\n"
    FILE_GROUP_REFS+="				${ref_uuid} /* ${filename} */,\n"
done

# Read the template sections we need to preserve (everything that isn't source files)
# We'll regenerate the entire pbxproj from a template

cat > "$PBXPROJ" << 'HEADER'
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
HEADER

# Write build file entries
echo -ne "$BUILD_FILE_ENTRIES" >> "$PBXPROJ"

# Framework build files (static)
cat >> "$PBXPROJ" << 'FRAMEWORKS_BUILD'
		A10000000000000000000004 /* XCTest.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A20000000000000000000005 /* XCTest.framework */; };
		A1000000000000000000000D /* GRDB in Frameworks */ = {isa = PBXBuildFile; productRef = A90000000000000000000001 /* GRDB */; };
		A1000000000000000000000F /* GhosttyKit.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = A20000000000000000000010 /* GhosttyKit.xcframework */; };
		A10000000000000000000010 /* ACP in Frameworks */ = {isa = PBXBuildFile; productRef = A90000000000000000000002 /* ACP */; };
		A10000000000000000000011 /* ACPModel in Frameworks */ = {isa = PBXBuildFile; productRef = A90000000000000000000003 /* ACPModel */; };
		A10000000000000000000012 /* CodeEditLanguages in Frameworks */ = {isa = PBXBuildFile; productRef = A90000000000000000000004 /* CodeEditLanguages */; };
		A10000000000000000000013 /* CodeEditSourceEditor in Frameworks */ = {isa = PBXBuildFile; productRef = A90000000000000000000005 /* CodeEditSourceEditor */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
FRAMEWORKS_BUILD

# Write file reference entries
echo -ne "$FILE_REF_ENTRIES" >> "$PBXPROJ"

# Static file references
cat >> "$PBXPROJ" << 'STATIC_REFS'
		A20000000000000000000004 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		A20000000000000000000005 /* XCTest.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = XCTest.framework; path = System/Library/Frameworks/XCTest.framework; sourceTree = SDKROOT; };
		A20000000000000000000006 /* ThreadmillUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ThreadmillUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		A20000000000000000000010 /* GhosttyKit.xcframework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = GhosttyKit.xcframework; path = ../GhosttyKit.xcframework; sourceTree = SOURCE_ROOT; };
/* End PBXFileReference section */

STATIC_REFS

# Now read the rest of the template from the existing file for groups, build settings, etc.
# We need to preserve: PBXFrameworksBuildPhase, PBXGroup, PBXNativeTarget, PBXProject,
# PBXSourcesBuildPhase, XCBuildConfiguration, XCConfigurationList, XCSwiftPackageProductDependency, XCRemoteSwiftPackageReference

# Generate the PBXGroup for UITest files
UITEST_FILE_REFS=""
for testfile in "$REPO_ROOT/UITests/ThreadmillUITests/"*.swift; do
    filename=$(basename "$testfile")
    hash=$(uuid_for_file "UITests/$filename")
    ref_uuid="A2${hash:0:22}"
    UITEST_FILE_REFS+="				${ref_uuid} /* ${filename} */,\n"
done

# Generate the PBXGroup for Threadmill source files  
THREADMILL_FILE_REFS=""
for filepath in $SOURCE_FILES; do
    relpath="${filepath#$REPO_ROOT/}"
    filename=$(basename "$filepath")
    hash=$(uuid_for_file "$relpath")
    ref_uuid="C2${hash:0:22}"
    THREADMILL_FILE_REFS+="				${ref_uuid} /* ${filename} */,\n"
done

cat >> "$PBXPROJ" << GROUPS
/* Begin PBXFrameworksBuildPhase section */
		A30000000000000000000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A10000000000000000000004 /* XCTest.framework in Frameworks */,
				A1000000000000000000000D /* GRDB in Frameworks */,
				A1000000000000000000000F /* GhosttyKit.xcframework in Frameworks */,
				A10000000000000000000010 /* ACP in Frameworks */,
				A10000000000000000000011 /* ACPModel in Frameworks */,
				A10000000000000000000012 /* CodeEditLanguages in Frameworks */,
				A10000000000000000000013 /* CodeEditSourceEditor in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A40000000000000000000001 = {
			isa = PBXGroup;
			children = (
				A40000000000000000000002 /* ThreadmillUITests */,
				A40000000000000000000003 /* Threadmill Sources */,
				A40000000000000000000004 /* Frameworks */,
				A40000000000000000000005 /* Products */,
			);
			sourceTree = "<group>";
		};
		A40000000000000000000002 /* ThreadmillUITests */ = {
			isa = PBXGroup;
			children = (
$(echo -ne "$UITEST_FILE_REFS")				A20000000000000000000004 /* Info.plist */,
			);
			path = ThreadmillUITests;
			sourceTree = "<group>";
		};
		A40000000000000000000003 /* Threadmill Sources */ = {
			isa = PBXGroup;
			children = (
$(echo -ne "$THREADMILL_FILE_REFS")			);
			name = "Threadmill Sources";
			sourceTree = "<group>";
		};
		A40000000000000000000004 /* Frameworks */ = {
			isa = PBXGroup;
			children = (
				A20000000000000000000005 /* XCTest.framework */,
				A20000000000000000000010 /* GhosttyKit.xcframework */,
			);
			name = Frameworks;
			sourceTree = "<group>";
		};
		A40000000000000000000005 /* Products */ = {
			isa = PBXGroup;
			children = (
				A20000000000000000000006 /* ThreadmillUITests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A50000000000000000000001 /* ThreadmillUITests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A70000000000000000000003 /* Build configuration list for PBXNativeTarget "ThreadmillUITests" */;
			buildPhases = (
				A60000000000000000000001 /* Sources */,
				A30000000000000000000001 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = ThreadmillUITests;
			packageProductDependencies = (
				A90000000000000000000001 /* GRDB */,
				A90000000000000000000002 /* ACP */,
				A90000000000000000000003 /* ACPModel */,
				A90000000000000000000004 /* CodeEditLanguages */,
				A90000000000000000000005 /* CodeEditSourceEditor */,
			);
			productName = ThreadmillUITests;
			productReference = A20000000000000000000006 /* ThreadmillUITests.xctest */;
			productType = "com.apple.product-type.bundle.ui-testing";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A50000000000000000000002 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 1600;
			};
			buildConfigurationList = A70000000000000000000001 /* Build configuration list for PBXProject "ThreadmillUITests" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A40000000000000000000001;
			packageReferences = (
				A80000000000000000000001 /* XCRemoteSwiftPackageReference "GRDB.swift" */,
				A80000000000000000000002 /* XCRemoteSwiftPackageReference "swift-acp" */,
				A80000000000000000000003 /* XCRemoteSwiftPackageReference "CodeEditSourceEditor" */,
				A80000000000000000000004 /* XCRemoteSwiftPackageReference "CodeEditLanguages" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = A40000000000000000000005 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A50000000000000000000001 /* ThreadmillUITests */,
			);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		A60000000000000000000001 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
$(echo -ne "$SOURCE_BUILD_REFS")			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

GROUPS

# Read existing build settings from the original file
# These are stable and don't change with file additions
cat >> "$PBXPROJ" << 'BUILD_SETTINGS'
/* Begin XCBuildConfiguration section */
		A70000000000000000000004 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = ThreadmillUITests/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/../Frameworks";
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.threadmill.uitests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 6.0;
				TEST_HOST = "";
				FRAMEWORK_SEARCH_PATHS = "$(inherited)";
				HEADER_SEARCH_PATHS = "$(inherited)";
				OTHER_LDFLAGS = (
					"-framework", "Metal",
					"-framework", "MetalKit",
					"-framework", "QuartzCore",
					"-framework", "WebKit",
				);
			};
			name = Debug;
		};
		A70000000000000000000005 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = ThreadmillUITests/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/../Frameworks";
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = dev.threadmill.uitests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 6.0;
				TEST_HOST = "";
				FRAMEWORK_SEARCH_PATHS = "$(inherited)";
				HEADER_SEARCH_PATHS = "$(inherited)";
				OTHER_LDFLAGS = (
					"-framework", "Metal",
					"-framework", "MetalKit",
					"-framework", "QuartzCore",
					"-framework", "WebKit",
				);
			};
			name = Release;
		};
		A70000000000000000000006 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
			};
			name = Debug;
		};
		A70000000000000000000007 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A70000000000000000000001 /* Build configuration list for PBXProject "ThreadmillUITests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A70000000000000000000006 /* Debug */,
				A70000000000000000000007 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
		A70000000000000000000003 /* Build configuration list for PBXNativeTarget "ThreadmillUITests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A70000000000000000000004 /* Debug */,
				A70000000000000000000005 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
/* End XCConfigurationList section */

/* Begin XCRemoteSwiftPackageReference / XCLocalSwiftPackageReference section */
		A80000000000000000000001 /* XCRemoteSwiftPackageReference "GRDB.swift" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/groue/GRDB.swift";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 7.4.1;
			};
		};
		A80000000000000000000002 /* XCRemoteSwiftPackageReference "swift-acp" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/wiedymi/swift-acp";
			requirement = {
				kind = branch;
				branch = main;
			};
		};
		A80000000000000000000003 /* XCLocalSwiftPackageReference "CodeEditSourceEditor" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../Packages/CodeEditSourceEditor;
		};
		A80000000000000000000004 /* XCLocalSwiftPackageReference "CodeEditLanguages" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = ../Packages/CodeEditLanguages;
		};
/* End XCRemoteSwiftPackageReference / XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		A90000000000000000000001 /* GRDB */ = {
			isa = XCSwiftPackageProductDependency;
			package = A80000000000000000000001 /* XCRemoteSwiftPackageReference "GRDB.swift" */;
			productName = GRDB;
		};
		A90000000000000000000002 /* ACP */ = {
			isa = XCSwiftPackageProductDependency;
			package = A80000000000000000000002 /* XCRemoteSwiftPackageReference "swift-acp" */;
			productName = ACP;
		};
		A90000000000000000000003 /* ACPModel */ = {
			isa = XCSwiftPackageProductDependency;
			package = A80000000000000000000002 /* XCRemoteSwiftPackageReference "swift-acp" */;
			productName = ACPModel;
		};
		A90000000000000000000004 /* CodeEditLanguages */ = {
			isa = XCSwiftPackageProductDependency;
			package = A80000000000000000000004 /* XCRemoteSwiftPackageReference "CodeEditLanguages" */;
			productName = CodeEditLanguages;
		};
		A90000000000000000000005 /* CodeEditSourceEditor */ = {
			isa = XCSwiftPackageProductDependency;
			package = A80000000000000000000003 /* XCRemoteSwiftPackageReference "CodeEditSourceEditor" */;
			productName = CodeEditSourceEditor;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = A50000000000000000000002 /* Project object */;
}
BUILD_SETTINGS

echo "Synced $(echo "$SOURCE_FILES" | wc -l | tr -d ' ') Threadmill source files to $PBXPROJ"
