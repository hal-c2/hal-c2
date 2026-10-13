#pragma once

#include <QString>

class World;

// "the user removes it", when "it" is the saved environment a connection
// scenario set up (ConnectionHealthSteps.cpp): removes it from Connections
// settings and returns true. False when the scenario has no such environment.
bool removeSavedEnvironment(World& world);

// "<command> is not offered", when the composer's command menu is open
// (UsageLimitsCommandSteps.cpp): fails the step if the menu offers it.
void expectCommandNotOffered(World& world, const QString& command);

// "<model> is offered in the model picker", for a model the scenario hid
// (ProviderListSteps.cpp): waits for the picker to offer it and returns true.
// False when the scenario hid none.
bool expectModelOffered(World& world, const QString& name);

// "the user runs <action>", when the scenario's MC runs the planner plugin
// (PlannerSteps.cpp): runs its action of that label from the Planner tab and
// returns true. False when the MC runs no planner.
bool runPluginAction(World& world, const QString& label);

// "the user opens <name>", when the scenario's MC runs the planner plugin and its
// plan has a view of that name (PlannerSteps.cpp): shows that view on the
// Planner tab and returns true. False otherwise.
bool openPlannerView(World& world, const QString& name);
