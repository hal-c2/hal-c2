#pragma once

#include <QString>

class World;

// The welcome wizard (OnboardingSteps.cpp), for the shared steps that read
// what the user sees and is told, and what the user chooses.

// The wizard or its recovery page is showing `text` as its title.
bool onboardingShows(World& world, const QString& text);
// The wizard tells the user `text`: a pairing, setup terminal or import error.
bool onboardingTells(World& world, const QString& text);
// Chooses the import step's "Select all" or "Select none", opening the
// wizard at that step with projects to choose from; false for other choices.
bool onboardingChooses(World& world, const QString& choice);
