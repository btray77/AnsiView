// CFPlugIn glue for the AnsiView Spotlight importer (.mdimporter). Spotlight loads this bundle,
// asks the factory for the URL import interface and calls AnsiViewImportURL, written in Swift.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>

#define PLUGIN_ID "CA227D08-16EB-4DF8-85A9-B12350FDAB21"

extern Boolean AnsiViewImportURL(CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFURLRef url);

typedef struct {
    MDImporterURLInterfaceStruct *interface;
    CFUUIDRef factoryID;
    UInt32 refCount;
} ImporterType;

static HRESULT QueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG AddRef(void *thisInstance);
static ULONG Release(void *thisInstance);

static Boolean ImportURL(void *thisInterface, CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI,
                         CFURLRef url) {
    return AnsiViewImportURL(attributes, contentTypeUTI, url);
}

static MDImporterURLInterfaceStruct interfaceFunctions = {
    NULL, QueryInterface, AddRef, Release, ImportURL
};

static ImporterType *AllocImporter(CFUUIDRef factoryID) {
    ImporterType *instance = (ImporterType *)malloc(sizeof(ImporterType));
    instance->interface = (MDImporterURLInterfaceStruct *)malloc(sizeof(MDImporterURLInterfaceStruct));
    memcpy(instance->interface, &interfaceFunctions, sizeof(MDImporterURLInterfaceStruct));
    instance->factoryID = (CFUUIDRef)CFRetain(factoryID);
    CFPlugInAddInstanceForFactory(factoryID);
    instance->refCount = 1;
    return instance;
}

static void DeallocImporter(ImporterType *instance) {
    CFUUIDRef factoryID = instance->factoryID;
    free(instance->interface);
    free(instance);
    if (factoryID) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

static HRESULT QueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(interfaceID, kMDImporterURLInterfaceID) || CFEqual(interfaceID, IUnknownUUID)) {
        ((ImporterType *)thisInstance)->interface->AddRef(thisInstance);
        *ppv = thisInstance;
        result = S_OK;
    } else {
        *ppv = NULL;
    }
    CFRelease(interfaceID);
    return result;
}

static ULONG AddRef(void *thisInstance) {
    return ++((ImporterType *)thisInstance)->refCount;
}

static ULONG Release(void *thisInstance) {
    ImporterType *instance = (ImporterType *)thisInstance;
    if (--instance->refCount == 0) {
        DeallocImporter(instance);
        return 0;
    }
    return instance->refCount;
}

// Named in Info.plist CFPlugInFactories.
void *AnsiViewImporterFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    if (CFEqual(typeID, kMDImporterTypeID)) {
        CFUUIDRef uuid = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR(PLUGIN_ID));
        ImporterType *result = AllocImporter(uuid);
        CFRelease(uuid);
        return result;
    }
    return NULL;
}
