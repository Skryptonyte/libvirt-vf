/*
 * vf_domain.h: data structures and functions to manage VF domain objects
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

#pragma once

#include <Foundation/Foundation.h>
#include "vf_conf.h"
#include "vf_private_api.h"

extern virDomainXMLPrivateDataCallbacks virVFDriverPrivateDataCallbacks;

@interface vfMachineDelegate: NSObject<VZVirtualMachineDelegate>
    @property virDomainObj *vm;
    @property (nonatomic, weak) virVFDriver *driver;

    - (void) stopVMForReason:(int) reason lockNeeded:(BOOL) needLock;
    - (void) guestDidStopVirtualMachine:(VZVirtualMachine *) virtualMachine;
    - (void) virtualMachine:(VZVirtualMachine *) virtualMachine 
             didStopWithError:(NSError *) error;
@end

@interface vfDomainObjPrivate: NSObject<VZVirtualMachineDelegate>
    @property (nonatomic, weak) virVFDriver *driver;
    @property (nonatomic, strong) VZVirtualMachine *machine;
    @property (nonatomic, strong) dispatch_queue_t vnc_queue;
    @property (nonatomic, strong) NSMutableArray *vnc_servers;

    @property (nonatomic, strong) vfMachineDelegate *delegate;
@end
