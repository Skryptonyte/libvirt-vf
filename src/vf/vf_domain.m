/*
 * vf_domain.m: data structures and functions to manage VF domain objects
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

#include "vf_domain.h"
#include "virlog.h"

VIR_LOG_INIT("vf.vf_domain");

@implementation vfDomainObjPrivate

@end

@implementation vfMachineDelegate
    - (void) stopVMForReason:(int)reason lockNeeded:(BOOL) needLock{
        size_t i;
        virDomainObj *vm = self.vm;
        vfDomainObjPrivate *priv = (__bridge vfDomainObjPrivate *) (vm->privateData);

        if (needLock)
            virObjectLock(vm);

        for (_VZVNCServer *server in priv.vnc_servers) {
            [server stop];
        }

        [priv.vnc_servers removeAllObjects];
        priv.vnc_queue = nil;

        priv.machine = nil;

        virDomainObjSetState(vm, VIR_DOMAIN_SHUTOFF, reason);
        vm->def->id = -1;

        if (needLock)
            virObjectUnlock(vm);
    }

    - (void) guestDidStopVirtualMachine:(VZVirtualMachine *) virtualMachine {
        [self stopVMForReason: VIR_DOMAIN_SHUTOFF_SHUTDOWN lockNeeded:YES];
    }

    - (void) virtualMachine:(VZVirtualMachine *) virtualMachine 
             didStopWithError:(NSError *) error {
        [self stopVMForReason: VIR_DOMAIN_SHUTOFF_CRASHED lockNeeded:YES];

    }
@end

static void
vfDomainObjPrivateFree(void *data)
{
    vfDomainObjPrivate *priv = (__bridge vfDomainObjPrivate *) (data);

    for (_VZVNCServer *server in priv.vnc_servers) {
        [server stop];
    }

    priv.vnc_servers = nil;
}


static void *
vfDomainObjPrivateAlloc(void *opaque)
{
    vfDomainObjPrivate *priv = [[vfDomainObjPrivate alloc] init];

    virVFDriver *driver = (__bridge virVFDriver *) (opaque);
    
    priv.vnc_servers = [[NSMutableArray alloc] init];

    return CFBridgingRetain(priv);
}


virDomainXMLPrivateDataCallbacks virVFDriverPrivateDataCallbacks = {
    .alloc = vfDomainObjPrivateAlloc,
    .free = vfDomainObjPrivateFree,
};
