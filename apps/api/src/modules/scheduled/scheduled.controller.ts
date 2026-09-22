import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';

import { formatMoney, money } from '../../domain/money';
import { CurrentUser } from '../auth/auth.guard';
import {
  ScheduledService,
  type CreateScheduleInput,
  type ScheduleView,
} from './scheduled.service';

function present(schedule: ScheduleView) {
  return {
    ...schedule,
    amountFormatted: formatMoney(money(schedule.amount, schedule.currency)),
  };
}

@Controller('schedules')
export class ScheduledController {
  constructor(private readonly schedules: ScheduledService) {}

  @Get()
  async list(@CurrentUser() userId: string, @Query('includeArchived') includeArchived?: string) {
    const rows = await this.schedules.list(userId, includeArchived === 'true');
    return {
      count: rows.length,
      dueSoon: rows.filter((s) => s.dueSoon).length,
      schedules: rows.map(present),
    };
  }

  /**
   * What is already committed over a horizon.
   *
   * Distinct from `/subscriptions`, which reports what *looks* recurring based
   * on history. This reports what the user said they owe.
   */
  @Get('upcoming')
  async upcoming(@CurrentUser() userId: string, @Query('days') days = '30') {
    const result = await this.schedules.upcoming(userId, Number(days));
    return {
      ...result,
      committedOutflowFormatted: result.committedOutflow === null || result.currency === null
        ? null : formatMoney(money(result.committedOutflow, result.currency)),
      entries: result.entries.map((entry) => ({
        ...entry,
        amountFormatted: formatMoney(money(entry.amount, entry.currency)),
      })),
    };
  }

  @Post()
  async create(@CurrentUser() userId: string, @Body() body: CreateScheduleInput) {
    return present(await this.schedules.create(userId, body));
  }

  @Patch(':id')
  async update(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() body: Partial<CreateScheduleInput>,
  ) {
    return present(await this.schedules.update(userId, id, body));
  }

  /** Archives rather than deletes, so past commitments stay explicable. */
  @Delete(':id')
  @HttpCode(204)
  async archive(@CurrentUser() userId: string, @Param('id') id: string): Promise<void> {
    await this.schedules.archive(userId, id);
  }
}
