<?php

declare(strict_types=1);

defined('BASEPATH') or exit('No direct script access allowed');

/*
Module Name: Plain Module
Description: The same minimal example module as Sample Module, without Composer: its classes are loaded with require_once and its tests run with php alone. It does nothing useful: it shows the shape a module needs to be deployed, checked on several PHP versions and tested against the test instance.
Version: 0.1.0
Requires at least: 3.4.0
*/

// There is no autoloader: the classes of the module are loaded by hand, here. deploy.sh copies this folder into the application
// as it is (it runs no "composer install" for a module without a composer.json), so every file listed below must be in it.
require_once __DIR__ . '/src/Greeting.php';

define('PLAIN_MODULE_NAME', 'plain_module');

// Runs once, when the module is activated from Setup > Modules. A module with tables of its own creates them here.
register_activation_hook(PLAIN_MODULE_NAME, 'plain_module_activation_hook');

function plain_module_activation_hook(): void
{
    // Nothing to create: this module has no tables.
}
