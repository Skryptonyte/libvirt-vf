/*
 * vf_machine.m: setup virtual machines for VF driver
 *
 * Copyright (C) 2025 Rayhan Faizel
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 */

#include "vf_machine.h"

#include <config.h>

#include "internal.h"
#include "virerror.h"
#include "virfile.h"
#include "virlog.h"
#include "vf_domain.h"
#include "vf_private_api.h"

#include <Foundation/Foundation.h>
#include <Virtualization/Virtualization.h>

VIR_LOG_INIT("vf.vf_machine");

static int vfConfigureRNG(virDomainDef *def,
                          VZVirtualMachineConfiguration *configuration)
{
    size_t i = 0;
    NSMutableArray *entropyDevices = [[NSMutableArray alloc] init];

    for (i = 0; i < def->nrngs; i++) {
        virDomainRNGDef *rng = def->rngs[i];
        VZVirtioEntropyDeviceConfiguration *entropy = [[VZVirtioEntropyDeviceConfiguration alloc] init];

        if (rng->backend != VIR_DOMAIN_RNG_BACKEND_BUILTIN) {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                           _("unsupported RNG backend '%1$s'"),
                           virDomainRNGBackendTypeToString(rng->backend));
            return -1;
        }
        [entropyDevices addObject:entropy];
    }

    configuration.entropyDevices = entropyDevices;
    return 0;
}


static int vfConfigureInputs(virDomainDef *def,
                             VZVirtualMachineConfiguration *configuration)
{
    size_t i = 0;
    NSMutableArray *keyboards = [[NSMutableArray alloc] init];
    NSMutableArray *pointingDevices = [[NSMutableArray alloc] init];

    for (i = 0; i < def->ninputs; i++) {
        virDomainInputDef *input = def->inputs[i];

        if (input->type == VIR_DOMAIN_INPUT_TYPE_KBD) {
            VZUSBKeyboardConfiguration *kbd = [[VZUSBKeyboardConfiguration alloc] init];
            [keyboards addObject:kbd];
        } else if (input->type == VIR_DOMAIN_INPUT_TYPE_MOUSE ||
                   input->type == VIR_DOMAIN_INPUT_TYPE_TABLET) {
            VZUSBScreenCoordinatePointingDeviceConfiguration *pointer =
                [[VZUSBScreenCoordinatePointingDeviceConfiguration alloc] init];
            [pointingDevices addObject:pointer];
        } else {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                _("unsupported input type '%1$s'"),
                virDomainInputTypeToString(input->type));
            return -1;
        }
    }

    configuration.keyboards = keyboards;
    configuration.pointingDevices = pointingDevices;

    return 0;
}


static int vfConfigureFilesystems(virDomainDef *def,
                                  VZVirtualMachineConfiguration *configuration)
{
    size_t i = 0;
    NSMutableArray *directorySharingDevices = [[NSMutableArray alloc] init];

    for (i = 0; i < def->nfss; i++) {
        virDomainFSDef *fs = def->fss[i];
        VZVirtioFileSystemDeviceConfiguration *fsConfig;
        VZSharedDirectory *shareDir;
        VZDirectoryShare *dirShare;

        NSString *source, *tag;
        NSURL *source_url;

        if (fs->type != VIR_DOMAIN_FS_TYPE_MOUNT &&
            fs->type != VIR_DOMAIN_FS_TYPE_ROSETTA) {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                           _("unsupported filesystem type '%1$s'"),
                           virDomainFSTypeToString(fs->type));
            return -1;
        }

        /* virtiofs is the only available driver type */
        if (fs->fsdriver == VIR_DOMAIN_FS_DRIVER_TYPE_DEFAULT) {
            fs->fsdriver = VIR_DOMAIN_FS_DRIVER_TYPE_VIRTIOFS;
        }

        if (fs->fsdriver != VIR_DOMAIN_FS_DRIVER_TYPE_VIRTIOFS) {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                           _("unsupported filesystem driver type '%1$s'"),
                           virDomainFSDriverTypeToString(fs->fsdriver));
            return -1;
        }

        tag = [NSString stringWithUTF8String:fs->dst];

        if (fs->type == VIR_DOMAIN_FS_TYPE_ROSETTA) {
            NSError *error;
            dirShare = [[VZLinuxRosettaDirectoryShare alloc] initWithError:&error];

            if (error) {
                virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                               _("rosetta is not available on this system"));
                return -1;
            }
        } else {
            source = [NSString stringWithUTF8String:fs->src->path];
            source_url = [NSURL fileURLWithPath:source];

            shareDir = [[VZSharedDirectory alloc]
                        initWithURL:source_url
                        readOnly:fs->readonly ? YES: NO];
            dirShare =  [[VZSingleDirectoryShare alloc] initWithDirectory:shareDir];
        }

        fsConfig = [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:tag];
        fsConfig.share = dirShare;

        [directorySharingDevices addObject:fsConfig];
    }

    configuration.directorySharingDevices = directorySharingDevices;
    return 0;
}


static int vfConfigureSounds(virDomainDef *def,
                             VZVirtualMachineConfiguration *configuration)
{
    size_t i;
    NSMutableArray *audioDevices = [[NSMutableArray alloc] init];


    for (i = 0; i < def->nsounds; i++) {
        virDomainSoundDef *sound = def->sounds[i];
        VZVirtioSoundDeviceConfiguration *soundConfig = [[VZVirtioSoundDeviceConfiguration alloc] init];
        NSMutableArray *streams = [[NSMutableArray alloc] init];

        if (sound->model != VIR_DOMAIN_SOUND_MODEL_VIRTIO) {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                            _("unsupported sound model: %1$s"),
                            virDomainSoundModelTypeToString(sound->model));
                            return -1;
        }

        VZVirtioSoundDeviceOutputStreamConfiguration *outputStream =
                [[VZVirtioSoundDeviceOutputStreamConfiguration alloc] init];
        outputStream.sink = [[VZHostAudioOutputStreamSink alloc] init];
        [streams addObject:outputStream];

        /* TODO: Add sound input configuration */

        soundConfig.streams = streams;
        [audioDevices addObject:soundConfig];
    }

    configuration.audioDevices = audioDevices;
    return 0;
}


static int vfConfigureVideos(virDomainDef *def,
                             VZVirtualMachineConfiguration *configuration)
{
    size_t i, j;
    NSMutableArray *graphicsDevices = [[NSMutableArray alloc] init];

    for (i = 0; i < def->nvideos; i++) {
        virDomainVideoDef *video = def->videos[i];
        NSMutableArray *scanouts = [[NSMutableArray alloc] init];
        NSInteger x=1280, y=720;

        if (video->type != VIR_DOMAIN_VIDEO_TYPE_VIRTIO) {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                    _("unsupported video model: %1$s"),
                    virDomainVideoTypeToString(video->type));
            return -1;
        }

        if (video->res) {
            x = video->res->x;
            y = video->res->y;
        }

        VZVirtioGraphicsDeviceConfiguration *videoConfig = [[VZVirtioGraphicsDeviceConfiguration alloc] init];

        for (j = 0; j < video->heads; j++) {
            [scanouts addObject:[[VZVirtioGraphicsScanoutConfiguration alloc]
                                    initWithWidthInPixels:x heightInPixels:y]];
        }
        videoConfig.scanouts = scanouts;

        [graphicsDevices addObject:videoConfig];
    }

    configuration.graphicsDevices = graphicsDevices;
    return 0;
}


static int vfConfigureDisplays(virDomainDef *def,
                               vfDomainObjPrivate *priv)
{
    size_t i = 0;

    for (i = 0; i < def->ngraphics; i++) {
        virDomainGraphicsDef *graphics = def->graphics[i];
        switch (graphics->type) {
        case VIR_DOMAIN_GRAPHICS_TYPE_VNC:
        {
            /* Use private API to instantiate a VNC server to stream display output.
             */
            _VZVNCServer *vnc_server = [[_VZVNCServer alloc]
                                        initWithPort:graphics->data.vnc.port
                                        queue:priv.vnc_queue];
            [vnc_server setVirtualMachine:priv.machine];
            [priv.vnc_servers addObject:vnc_server];
            [vnc_server start];
            break;
        }
        case VIR_DOMAIN_GRAPHICS_TYPE_SDL:
        case VIR_DOMAIN_GRAPHICS_TYPE_SPICE:
        case VIR_DOMAIN_GRAPHICS_TYPE_EGL_HEADLESS:
        case VIR_DOMAIN_GRAPHICS_TYPE_DBUS:
        case VIR_DOMAIN_GRAPHICS_TYPE_RDP:
        case VIR_DOMAIN_GRAPHICS_TYPE_DESKTOP:
        case VIR_DOMAIN_GRAPHICS_TYPE_LAST:
        default:
            virReportEnumRangeError(virDomainGraphicsType, graphics->type);
        }
    }

    return 0;
}


static int vfConfigureNetwork(virDomainDef *def,
                              VZVirtualMachineConfiguration *configuration)
{
    size_t i = 0;
    NSMutableArray *networkDevices = [[NSMutableArray alloc] init];

    for (i = 0; i < def->nnets; i++) {
        VZVirtioNetworkDeviceConfiguration *networkConfig = [[VZVirtioNetworkDeviceConfiguration alloc] init];
        virDomainNetDef *net = def->nets[i];
        virDomainNetType actualType = virDomainNetGetActualType(net);
        char mac[VIR_MAC_STRING_BUFLEN];
        NSString *mac_address;

        if (net->model == VIR_DOMAIN_NET_MODEL_UNKNOWN) {
            net->model = VIR_DOMAIN_NET_MODEL_VIRTIO;
        } else if (net->model != VIR_DOMAIN_NET_MODEL_VIRTIO) {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                        _("unsupported network model: %1$s"),
                        virDomainNetModelTypeToString(net->model));
            return -1;
        }

        switch (actualType) {
        case VIR_DOMAIN_NET_TYPE_USER:
        {
            /* NAT networking */
            VZNATNetworkDeviceAttachment *attach = [[VZNATNetworkDeviceAttachment alloc] init];
            networkConfig.attachment = attach;

            break;
        }
        case VIR_DOMAIN_NET_TYPE_BRIDGE:
        /* TODO: Implement bridged attachment */

        case VIR_DOMAIN_NET_TYPE_NETWORK:
        /* TODO: Implement vmnet attachment available as of macOS 26 */

        case VIR_DOMAIN_NET_TYPE_UDP:
        /* TODO: Implement file based socket attachment */

        case VIR_DOMAIN_NET_TYPE_ETHERNET:
        case VIR_DOMAIN_NET_TYPE_VHOSTUSER:
        case VIR_DOMAIN_NET_TYPE_SERVER:
        case VIR_DOMAIN_NET_TYPE_CLIENT:
        case VIR_DOMAIN_NET_TYPE_MCAST:
        case VIR_DOMAIN_NET_TYPE_INTERNAL:
        case VIR_DOMAIN_NET_TYPE_DIRECT:
        case VIR_DOMAIN_NET_TYPE_HOSTDEV:
        case VIR_DOMAIN_NET_TYPE_VDPA:
        case VIR_DOMAIN_NET_TYPE_NULL:
        case VIR_DOMAIN_NET_TYPE_VDS:
        case VIR_DOMAIN_NET_TYPE_LAST:
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                           _("unsupported network type '%1$s'"),
                           virDomainNetTypeToString(actualType));
            return -1;
        }

        virMacAddrFormat(&net->mac, mac);
        mac_address = [NSString stringWithUTF8String:mac];

        networkConfig.MACAddress = [[VZMACAddress alloc] initWithString:mac_address];

        [networkDevices addObject: networkConfig];
    }

    configuration.networkDevices = networkDevices;
    return 0;
}


static VZStorageDeviceAttachment *
vfBuildDiskNBDAttachment(virDomainDiskDef *disk)
{
    virStorageSource *src = disk->src;
    virStorageNetHostDef *host;
    NSString *nbd_url_string;
    g_autofree char *url_string;
    NSURL *nbd_url;
    VZNetworkBlockDeviceStorageDeviceAttachment *attach;

    if (src->protocol != VIR_STORAGE_NET_PROTOCOL_NBD) {
        virReportEnumRangeError(virStorageNetProtocol, src->protocol);
        return nil;
    }

    if (src->nhosts != 1) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                    _("nbd protocol accepts only one host"));
        return nil;
    }

    host = &src->hosts[0];

    if (src->path)
        url_string = g_strdup_printf("nbd://%s:%d/%s",
                                     host->name,
                                     host->port,
                                     src->path);
    else
        url_string = g_strdup_printf("nbd://%s:%d", host->name, host->port);

    nbd_url_string = [NSString stringWithUTF8String:url_string];
    nbd_url = [[NSURL alloc] initWithString:nbd_url_string];

    attach = [[VZNetworkBlockDeviceStorageDeviceAttachment alloc]
                initWithURL:nbd_url
                timeout:5.0
                forcedReadOnly:src->readonly
                synchronizationMode:VZDiskSynchronizationModeFull
                error:nil];

    if (!attach) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                    _("failed to create NBD attachment for disk"));
        return nil;
    }

    return attach;
}


static VZStorageDeviceAttachment *
vfBuildDiskBlockAttachment(virDomainDiskDef *disk,
                            BOOL privileged)
{
    NSString *diskPath = [NSString stringWithUTF8String:disk->src->path];
    NSFileHandle *filehandle = [NSFileHandle fileHandleForUpdatingAtPath:diskPath];
    VZDiskBlockDeviceStorageDeviceAttachment *attach;

    if (!privileged) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                        _("Disk block type can only be used in system mode"));
        return nil;
    }

    if (!filehandle) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                        _("Unable to create file handle for path: %1$s"), disk->src->path);
        return nil;
    }

    attach = [[VZDiskBlockDeviceStorageDeviceAttachment alloc]
                initWithFileHandle:filehandle
                readOnly:disk->src->readonly
                synchronizationMode:VZDiskSynchronizationModeFull
                error:nil];

    if (!attach) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                    _("failed to create block attachment for disk"));
        return nil;
    }

    return attach;
}


static VZStorageDeviceAttachment *
vfBuildDiskFileAttachment(virDomainDiskDef *disk)
{
    NSString *diskPath = [NSString stringWithUTF8String:disk->src->path];
    NSURL *path_url = [NSURL fileURLWithPath:diskPath];

    VZDiskImageStorageDeviceAttachment *attach =
                    [[VZDiskImageStorageDeviceAttachment alloc]
                      initWithURL:path_url
                      readOnly:disk->src->readonly
                      error:nil];

    if (!attach) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                    _("failed to create file attachment for disk"));
        return nil;
    }

    return attach;
}


static int vfConfigureDisks(virDomainDef *def,
                            VZVirtualMachineConfiguration *configuration,
                            BOOL privileged)
{
    size_t i = 0;
    NSMutableArray *storageDevices = [[NSMutableArray alloc] init];

    for (i = 0; i < def->ndisks; i++) {
        VZStorageDeviceConfiguration *storageConfig;
        VZStorageDeviceAttachment *attach;
        virDomainDiskDef *disk = def->disks[i];

        switch (disk->src->type) {
        case VIR_STORAGE_TYPE_FILE:
            if (!(attach = vfBuildDiskFileAttachment(disk)))
                return -1;

            break;
        case VIR_STORAGE_TYPE_BLOCK:
            if (!(attach = vfBuildDiskBlockAttachment(disk, privileged)))
                return -1;

            break;
        case VIR_STORAGE_TYPE_NETWORK:
            if (!(attach = vfBuildDiskNBDAttachment(disk)))
                return -1;

            break;
        case VIR_STORAGE_TYPE_NONE:
        case VIR_STORAGE_TYPE_DIR:
        case VIR_STORAGE_TYPE_VOLUME:
        case VIR_STORAGE_TYPE_NVME:
        case VIR_STORAGE_TYPE_VHOST_USER:
        case VIR_STORAGE_TYPE_VHOST_VDPA:
        case VIR_STORAGE_TYPE_LAST:
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
            _("unsupported storage source type '%1$s'"),
            virStorageTypeToString(disk->bus));
            return -1;
        }

        switch (disk->bus) {
        case VIR_DOMAIN_DISK_BUS_VIRTIO:
            storageConfig = [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:attach];

            break;
        case VIR_DOMAIN_DISK_BUS_USB:
            storageConfig = [[VZUSBMassStorageDeviceConfiguration alloc] initWithAttachment:attach];

            break;
        case VIR_DOMAIN_DISK_BUS_NVME:
            storageConfig = [[VZNVMExpressControllerDeviceConfiguration alloc] initWithAttachment:attach];

            break;
        case VIR_DOMAIN_DISK_BUS_NONE:
        case VIR_DOMAIN_DISK_BUS_IDE:
        case VIR_DOMAIN_DISK_BUS_FDC:
        case VIR_DOMAIN_DISK_BUS_SCSI:
        case VIR_DOMAIN_DISK_BUS_XEN:
        case VIR_DOMAIN_DISK_BUS_UML:
        case VIR_DOMAIN_DISK_BUS_SATA:
        case VIR_DOMAIN_DISK_BUS_SD:
        case VIR_DOMAIN_DISK_BUS_LAST:
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
            _("unsupported disk bus '%1$s'"),
            virDomainDiskBusTypeToString(disk->bus));
            return -1;
        }

        [storageDevices addObject:storageConfig];
    }

    configuration.storageDevices = storageDevices;
    return 0;
}


static int vfConfigureSerial(virDomainDef *def,
                             VZVirtualMachineConfiguration *configuration)
{
    NSMutableArray *serialPorts = [[NSMutableArray alloc] init];

    for (size_t i = 0; i < def->nserials; i++) {
        virDomainChrDef *serial = def->serials[i];
        virDomainChrSourceDef *source = serial->source;
        VZVirtioConsoleDeviceSerialPortConfiguration *serialPortConfig = nil;
        NSFileHandle *readHandle = nil;
        NSFileHandle *writeHandle = nil;

        switch (source->type) {
            case VIR_DOMAIN_CHR_TYPE_PTY:
                int master_fd;
                char *ttyPath;

                if (virFileOpenTty(&master_fd, &ttyPath, 1) < 0 ) {
                    virReportError(VIR_ERR_INTERNAL_ERROR,
                                _("failed to open tty"));
                    return -1;
                }

                readHandle = [[NSFileHandle alloc] initWithFileDescriptor:master_fd closeOnDealloc:true];
                writeHandle = [[NSFileHandle alloc] initWithFileDescriptor:master_fd closeOnDealloc:true];

                source->data.file.path = ttyPath;

                break;
            case VIR_DOMAIN_CHR_TYPE_TCP:
            case VIR_DOMAIN_CHR_TYPE_FILE:
            case VIR_DOMAIN_CHR_TYPE_UNIX:
            case VIR_DOMAIN_CHR_TYPE_NULL:
            case VIR_DOMAIN_CHR_TYPE_VC:
            case VIR_DOMAIN_CHR_TYPE_DEV:
            case VIR_DOMAIN_CHR_TYPE_PIPE:
            case VIR_DOMAIN_CHR_TYPE_STDIO:
            case VIR_DOMAIN_CHR_TYPE_UDP:
            case VIR_DOMAIN_CHR_TYPE_SPICEVMC:
            case VIR_DOMAIN_CHR_TYPE_SPICEPORT:
            case VIR_DOMAIN_CHR_TYPE_QEMU_VDAGENT:
            case VIR_DOMAIN_CHR_TYPE_DBUS:
            case VIR_DOMAIN_CHR_TYPE_NMDM:
            case VIR_DOMAIN_CHR_TYPE_LAST:
            default:
                virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                            _("unsupported chardev '%1$s'"),
                            virDomainChrTypeToString(source->type));
                return -1;
        }

        serialPortConfig = [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
        VZFileHandleSerialPortAttachment *attach = [[VZFileHandleSerialPortAttachment alloc]
                                                    initWithFileHandleForReading:readHandle
                                                    fileHandleForWriting:writeHandle];

        serialPortConfig.attachment = attach;

        [serialPorts addObject:serialPortConfig];
    }

    configuration.serialPorts = serialPorts;
    return 0;
}


static int vfConfigureMemory(virDomainDef *def,
                             VZVirtualMachineConfiguration *configuration)
{
    /* Libvirt stores memory in KiB, but Virtualization.Framework expects memory in bytes */
    uint64_t memsize = virDomainDefGetMemoryInitial(def) * 1024;
    configuration.memorySize = memsize;

    if (def->memballoon) {
        virDomainMemballoonDef *memballoon = def->memballoon;

        if (memballoon->model != VIR_DOMAIN_MEMBALLOON_MODEL_VIRTIO) {
            virReportError(VIR_ERR_CONFIG_UNSUPPORTED,
                           _("unsupported memballoon model '%1$s'"),
                            virDomainMemballoonModelTypeToString(memballoon->model));
            return -1;
        }

        VZVirtioTraditionalMemoryBalloonDeviceConfiguration *balloonConfig =
                            [[VZVirtioTraditionalMemoryBalloonDeviceConfiguration alloc] init];
        configuration.memoryBalloonDevices = @[ balloonConfig ];
    }

    return 0;
}


static int vfConfigureCPU(virDomainDef *def,
                          VZVirtualMachineConfiguration *configuration)
{
    unsigned int nvcpus = virDomainDefGetVcpusMax(def);
    configuration.CPUCount = nvcpus;

    return 0;
}


static int vfConfigureBootloader(virDomainDef *def,
                                 VZVirtualMachineConfiguration *configuration,
                                 virVFConf *cfg)
{
    if (def->os.kernel) {
        /* If <kernel> is present, use VZLinuxBootloader */
        NSString *kernel = [NSString stringWithUTF8String:def->os.kernel];
        NSURL *kernel_url = [NSURL fileURLWithPath:kernel];
        VZLinuxBootLoader *bootloader = nil;

        if (kernel_url == nil) {
            virReportError(VIR_ERR_INTERNAL_ERROR,
                _("Kernel URL is invalid."));
            return -1;
        }

        bootloader = [[VZLinuxBootLoader alloc] initWithKernelURL:kernel_url];

        if (def->os.initrd) {
            NSString *ramdisk = [NSString stringWithUTF8String:def->os.initrd];
            NSURL *ramdisk_url = [NSURL fileURLWithPath:ramdisk];

            if (kernel_url == nil) {
                virReportError(VIR_ERR_INTERNAL_ERROR,
                    _("Ramdisk URL is invalid."));
                return -1;
            }

            bootloader.initialRamdiskURL = ramdisk_url;
        }

        if (def->os.cmdline) {
            NSString *cmdline = [NSString stringWithUTF8String:def->os.cmdline];
            bootloader.commandLine = cmdline;
        }

        configuration.bootLoader = bootloader;
    } else {
        /* Otherwise, use VZEFIBootloader to boot drives via EFI */
        VZEFIBootLoader *bootloader = [[VZEFIBootLoader alloc] init];
        g_autofree char *filePathUtf8 = g_strdup_printf("%s/%s_VARS.fd", cfg->nvramDir, def->name);
        NSString *filePath = [NSString stringWithUTF8String: filePathUtf8];
        NSURL *fileURL = [NSURL fileURLWithPath:filePath];
        NSError *error = nil;
        VZEFIVariableStore *variableStore;

        if (!virFileExists(filePathUtf8))
            variableStore = [[VZEFIVariableStore alloc]
                              initCreatingVariableStoreAtURL:fileURL
                              options:VZEFIVariableStoreInitializationOptionAllowOverwrite
                              error:&error];
        else
            variableStore = [[VZEFIVariableStore alloc]
                              initWithURL:fileURL];

        if (error) {
            virReportError(VIR_ERR_INTERNAL_ERROR,
                            _("Failed to create EFI NVRAM for VM '%1$s': %2$s"),
                            def->name, [[error localizedDescription] UTF8String]);
            return -1;
        }

        bootloader.variableStore = variableStore;
        configuration.bootLoader = bootloader;
    }

    return 0;
}


static int vfConfigurePlatform(virDomainDef *def,
                               VZVirtualMachineConfiguration *configuration)
{
    VZGenericPlatformConfiguration *platform = [[VZGenericPlatformConfiguration alloc] init];
    platform.machineIdentifier = [[VZGenericMachineIdentifier alloc] init];

    if (def->vf_features[VIR_DOMAIN_VF_NESTED] == VIR_TRISTATE_SWITCH_ON) {
        platform.nestedVirtualizationEnabled = YES;
    }

    configuration.platform = platform;

    return 0;
}


int vfStopMachine(virVFDriver *driver, virDomainObj *vm)
{
    __block vfDomainObjPrivate *priv = (__bridge vfDomainObjPrivate *) vm->privateData;
    __block NSError *error = nil;
    __block dispatch_semaphore_t sync_vm_sem = dispatch_semaphore_create(0);

    dispatch_sync(driver.queue, ^{
        VZVirtualMachine *machine = priv.machine;
        [machine stopWithCompletionHandler:^(NSError * _Nullable vm_error) {
            if (vm_error != nil) {
                error = [vm_error copy];
            }

            dispatch_semaphore_signal(sync_vm_sem);
        }];
    });

    if (error) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                _("Failed to destroy domain '%1$s': %2$s"),
                vm->def->name, [[error localizedDescription] UTF8String]);
        return -1;
    }

    virDomainObjSetState(vm, VIR_DOMAIN_SHUTOFF, VIR_DOMAIN_SHUTOFF_DESTROYED);
    vm->def->id = -1;

    return 0;
}


int vfStartMachine(virVFDriver *driver, virDomainObj *vm)
{
    virDomainDef *def = vm->def;
    vfDomainObjPrivate *priv = (__bridge vfDomainObjPrivate *) (vm->privateData);
    VZVirtualMachineConfiguration *configuration = [VZVirtualMachineConfiguration new];
    dispatch_semaphore_t sync_vm_sem = dispatch_semaphore_create(0);

    __block NSError *error = nil;
    __block BOOL vmStartSuccess = NO;

    priv.vnc_queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);

    if (vfConfigurePlatform(def, configuration) < 0)
        return -1;

    if (vfConfigureBootloader(def, configuration, driver.cfg) < 0)
        return -1;

    if (vfConfigureCPU(def, configuration) < 0)
        return -1;

    if (vfConfigureMemory(def, configuration) < 0)
        return -1;

    if (vfConfigureSerial(def, configuration) < 0)
        return -1;

    if (vfConfigureDisks(def, configuration, driver.privileged) < 0)
        return -1;

    if (vfConfigureNetwork(def, configuration) < 0)
        return -1;

    if (vfConfigureVideos(def, configuration) < 0)
        return -1;

    if (vfConfigureSounds(def, configuration) < 0)
        return -1;

    if (vfConfigureFilesystems(def, configuration) < 0)
        return -1;

    if (vfConfigureInputs(def, configuration) < 0)
        return -1;

    if (vfConfigureRNG(def, configuration) < 0)
        return -1;

    BOOL validConfig = [configuration validateWithError:&error];

    if (!validConfig) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                _("Failed to start VM '%1$s': %2$s"),
                def->name, [[error localizedDescription] UTF8String]);
        return -1;
    }

    priv.machine = [[VZVirtualMachine alloc] initWithConfiguration:configuration queue:driver.queue];

    priv.delegate = [[vfMachineDelegate alloc] init];
    priv.delegate.vm = vm;
    priv.delegate.driver = driver;

    priv.machine.delegate = priv.delegate;

    if (vfConfigureDisplays(def, priv) < 0)
        return -1;

    dispatch_sync(driver.queue, ^{
        VZVirtualMachine *machine = priv.machine;
        [machine startWithCompletionHandler:^(NSError * _Nullable vm_error) {
            if (vm_error != nil) {
                error = [vm_error copy];
            } else {
                vmStartSuccess = YES;
            }

            dispatch_semaphore_signal(sync_vm_sem);
        }];
    });

    dispatch_semaphore_wait(sync_vm_sem, DISPATCH_TIME_FOREVER);

    if (!vmStartSuccess) {
        virReportError(VIR_ERR_INTERNAL_ERROR,
                _("Failed to start VM '%1$s': %2$s"),
                def->name, [[error localizedDescription] UTF8String]);
        return -1;
    }

    vm->def->id = [driver allocateVMID];
    virDomainObjSetState(vm, VIR_DOMAIN_RUNNING, VIR_DOMAIN_RUNNING_BOOTED);

    return 0;
}
